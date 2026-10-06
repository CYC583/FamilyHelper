#!/usr/bin/env python3
# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""FamilyHelper 一鍵設定精靈。

把「建立自己的 Firebase 後端 → 部署 → 產生簽章金鑰 → 打包兩個 APK」
串成一個問答流程。每一步完成後會記在 .setup/state.json，中斷後重新執行
會從上次停下的地方繼續。

    python3 tool/setup.py            # 從頭或接續上次
    python3 tool/setup.py --from 6   # 從第 6 步重新開始
    python3 tool/setup.py --check    # 只檢查電腦環境

這個腳本不會把任何金鑰或密碼印在畫面上，也不會上傳到 Firebase 以外的地方。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / '.setup'
STATE_FILE = STATE_DIR / 'state.json'
BACKEND = ROOT / 'backend'
FUNCTIONS = BACKEND / 'functions'
FIREBASE_TOOLS = 'firebase-tools@15.26.0'
PACKAGES = {'host': 'com.familyhelper.host', 'client': 'com.familyhelper.client'}
APP_NAMES = {'host': 'FamilyHelper 長輩版', 'client': 'FamilyHelper 家人版'}
PROJECT_ID = re.compile(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$')
DB_REGIONS = {
    '1': ('asia-southeast1', '新加坡（台灣、香港、東南亞建議）'),
    '2': ('europe-west1', '比利時（歐洲）'),
    '3': ('us-central1', '美國'),
}

# ── 畫面輸出 ──────────────────────────────────────────────────────────────

USE_COLOR = sys.stdout.isatty() and os.environ.get('NO_COLOR') is None


def _c(code: str, text: str) -> str:
    return f'\033[{code}m{text}\033[0m' if USE_COLOR else text


def title(n: int, total: int, text: str) -> None:
    print()
    print(_c('1;32', f'━━ 第 {n}/{total} 步：{text} ━━'))


def info(text: str) -> None:
    print(f'  {text}')


def ok(text: str) -> None:
    print(_c('32', f'  ✓ {text}'))


def warn(text: str) -> None:
    print(_c('33', f'  ! {text}'))


def fail(text: str) -> None:
    print(_c('31', f'  ✗ {text}'))


def ask(prompt: str, default: str | None = None) -> str:
    suffix = f'（直接按 Enter = {default}）' if default else ''
    while True:
        try:
            answer = input(_c('1', f'  ? {prompt}{suffix}：')).strip()
        except EOFError:
            print()
            sys.exit('已取消。之後重新執行會從這一步繼續。')
        if answer:
            return answer
        if default is not None:
            return default


def confirm(prompt: str, default: bool = True) -> bool:
    hint = 'Y/n' if default else 'y/N'
    answer = ask(f'{prompt} [{hint}]', 'y' if default else 'n').lower()
    return answer in ('y', 'yes', '是', '好')


def wait_for_user(url: str, steps: list[str]) -> None:
    """Show a console page the user must visit, open it, and wait."""
    for i, step in enumerate(steps, 1):
        info(f'{i}. {step}')
    info(_c('4', url))
    try:
        webbrowser.open(url)
    except Exception:  # noqa: BLE001 - opening a browser is best-effort
        pass
    ask('完成後按 Enter 繼續', '')


# ── 狀態 ──────────────────────────────────────────────────────────────────


def load_state() -> dict:
    if STATE_FILE.is_file():
        return json.loads(STATE_FILE.read_text(encoding='utf-8'))
    return {'done': []}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


# ── 外部指令 ──────────────────────────────────────────────────────────────


def firebase_cmd() -> list[str]:
    firebase_path = shutil.which('firebase')
    if firebase_path:
        return [firebase_path]
    npx_path = shutil.which('npx')
    if not npx_path:
        raise SetupError('找不到 Firebase CLI 或 npx，請先安裝 Node.js。', [])
    return [npx_path, '--yes', FIREBASE_TOOLS]


def run(args: list[str], *, cwd: Path = ROOT, capture: bool = False,
        stdin: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    """Run a command. Interactive commands (capture=False) use the terminal."""
    result = subprocess.run(
        args, cwd=cwd, text=True, input=stdin,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or '').strip().splitlines()[-3:] if capture else []
        raise SetupError(f'指令失敗：{" ".join(args[:4])}…', detail)
    return result


def firebase(args: list[str], project: str | None = None, **kw) -> subprocess.CompletedProcess:
    full = firebase_cmd() + args + (['--project', project] if project else [])
    return run(full, cwd=kw.pop('cwd', BACKEND), **kw)


def firebase_json(args: list[str], project: str | None = None) -> dict:
    result = firebase(args + ['--json'], project, capture=True, check=False)
    try:
        data = json.loads(result.stdout or '{}')
    except json.JSONDecodeError as e:
        raise SetupError('Firebase CLI 回傳的不是預期格式', [str(e)]) from e
    if result.returncode != 0 or data.get('status') == 'error':
        raise SetupError(data.get('error', 'Firebase CLI 執行失敗'), [])
    return data


class SetupError(Exception):
    def __init__(self, message: str, detail: list[str]):
        super().__init__(message)
        self.detail = detail


# ── 各步驟 ────────────────────────────────────────────────────────────────


def version_of(cmd: list[str]) -> str:
    executable = shutil.which(cmd[0])
    if not executable:
        return ''
    try:
        r = subprocess.run([executable, *cmd[1:]], text=True,
                           capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return ''
    return (r.stdout + r.stderr).strip()


def step_check(_: dict) -> None:
    """確認電腦上有需要的工具。"""
    problems = []
    py = sys.version_info
    ok(f'Python {py.major}.{py.minor}')

    flutter = version_of(['flutter', '--version'])
    if not flutter:
        problems.append('找不到 Flutter。安裝：https://docs.flutter.dev/get-started/install（建議 3.35.7）')
    else:
        v = re.search(r'Flutter (\d+\.\d+\.\d+)', flutter)
        ok(f'Flutter {v.group(1) if v else "（版本未知）"}')
        if v and not v.group(1).startswith('3.35'):
            warn('本專案以 Flutter 3.35.7 驗證；其他版本可能無法編譯。')

    java = version_of(['java', '-version'])
    m = re.search(r'version "(\d+)', java)
    if not m:
        problems.append('找不到 Java。請安裝 JDK 17（例如 Temurin 17）。')
    elif m.group(1) != '17':
        warn(f'偵測到 Java {m.group(1)}；Android 建置以 JDK 17 驗證。')
    else:
        ok('Java 17')

    node = version_of(['node', '--version'])
    m = re.search(r'v(\d+)', node)
    if not m:
        problems.append('找不到 Node.js。請安裝 Node.js 22：https://nodejs.org/')
    elif int(m.group(1)) < 22:
        problems.append(f'Node.js 版本是 {node}，需要 22 以上。')
    else:
        ok(f'Node.js {node}')

    if shutil.which('firebase'):
        ok('Firebase CLI（已安裝）')
    elif shutil.which('npx'):
        ok(f'Firebase CLI（會用 npx 自動下載 {FIREBASE_TOOLS}）')
    else:
        problems.append('找不到 npx（Node.js 附帶），無法使用 Firebase CLI。')

    android = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if android or (ROOT / 'android' / 'local.properties').is_file():
        ok('Android SDK')
    else:
        warn('沒有設定 ANDROID_HOME；若打包失敗，請先執行 flutter doctor。')

    if problems:
        for p in problems:
            fail(p)
        raise SetupError('請先安裝上面缺少的工具，再重新執行。', [])


def step_login(state: dict) -> None:
    """登入 Google 帳號（用來建立 Firebase 專案）。"""
    result = firebase(['login:list'], capture=True, check=False)
    accounts = re.findall(r'[\w.+-]+@[\w-]+\.[\w.-]+', result.stdout or '')
    if accounts:
        ok(f'已登入 {accounts[0]}')
        if confirm('要用這個帳號嗎？'):
            return
    info('瀏覽器會開啟 Google 登入頁面。')
    firebase(['login', '--reauth'])


def step_project(state: dict) -> None:
    """建立或選擇 Firebase 專案。"""
    info('每個家庭使用自己的 Firebase 專案；資料不會和其他家庭共用。')
    if confirm('要建立新的 Firebase 專案嗎？（已經有專案請選 n）'):
        while True:
            pid = ask('專案 ID（小寫英文、數字、減號，6–30 字，例如 familyhelper-chen）')
            if PROJECT_ID.match(pid):
                break
            fail('格式不符：要以小寫英文開頭，只能有小寫英文、數字和減號。')
        firebase(['projects:create', pid, '--display-name', 'FamilyHelper'])
    else:
        pid = ask('既有的專案 ID')
        if not PROJECT_ID.match(pid):
            raise SetupError('專案 ID 格式不符', [])
    state['project'] = pid
    ok(f'使用專案 {pid}')


def step_console(state: dict) -> None:
    """在 Firebase 網頁開啟付費方案、匿名登入、資料庫與儲存空間。"""
    pid = state['project']
    console = f'https://console.firebase.google.com/project/{pid}'

    print()
    info(_c('1', 'A. 升級為 Blaze（用量計費）方案'))
    info('Cloud Functions 需要 Blaze 方案。一般家庭用量通常很低，但費用依實際用量計算，')
    info('建議在 Google Cloud 設定「預算提醒」。本專案不保證免費。')
    wait_for_user(f'{console}/usage/details', ['按「修改方案」→ 選 Blaze → 綁定付款方式'])

    print()
    info(_c('1', 'B. 開啟「匿名」登入'))
    wait_for_user(f'{console}/authentication/providers', [
        '若看到「開始使用」先按下去',
        '在「登入方式」找到「匿名」→ 啟用 → 儲存',
    ])

    print()
    info(_c('1', 'C. 建立 Realtime Database'))
    for key, (_, label) in DB_REGIONS.items():
        info(f'{key}. {label}')
    region = DB_REGIONS.get(ask('資料庫位置', '1'), DB_REGIONS['1'])[0]
    instance = f'{pid}-default-rtdb'
    created = firebase(['database:instances:create', instance, '--location', region],
                       pid, capture=True, check=False)
    if created.returncode == 0:
        ok('已建立資料庫')
    else:
        warn('無法自動建立，請在網頁手動建立（選「鎖定模式」）。')
        wait_for_user(f'{console}/database', ['按「建立資料庫」', f'位置選 {region}', '選「以鎖定模式啟動」'])
    guess = (f'https://{instance}.firebaseio.com' if region == 'us-central1'
             else f'https://{instance}.{region}.firebasedatabase.app')
    url = ask('資料庫網址（網頁上方顯示的 https://… 網址）', guess).rstrip('/')
    if not re.match(r'^https://[a-z0-9-]+\.(firebaseio\.com|[a-z0-9-]+\.firebasedatabase\.app)$', url):
        raise SetupError('資料庫網址格式不符', [url])
    state['databaseUrl'] = url

    print()
    info(_c('1', 'D. 建立 Storage（照片分享與語音需要，建議開啟）'))
    if confirm('要開啟照片與語音功能嗎？'):
        wait_for_user(f'{console}/storage', ['按「開始使用」', '選「以正式版模式啟動」', '位置選和資料庫相近的區域'])
        state['storageBucket'] = ask('Storage bucket 名稱（網頁上 gs:// 後面那段）', f'{pid}.firebasestorage.app')
    else:
        state['storageBucket'] = ''
        warn('不開啟 Storage：照片分享與語音留言將無法使用，之後可以重跑 --from 4 再開。')


def _find_or_create_app(pid: str, role: str) -> str:
    apps = firebase_json(['apps:list', 'ANDROID'], pid).get('result', [])
    for app in apps:
        if app.get('packageName') == PACKAGES[role]:
            return app['appId']
    created = firebase_json(['apps:create', 'ANDROID', APP_NAMES[role],
                             '--package-name', PACKAGES[role]], pid)
    return created['result']['appId']


def step_apps(state: dict) -> None:
    """在 Firebase 註冊長輩版與家人版兩個 Android App。"""
    pid = state['project']
    downloads = {}
    for role in ('host', 'client'):
        app_id = _find_or_create_app(pid, role)
        out = STATE_DIR / f'{role}-google-services.json'
        if out.exists():
            out.unlink()
        firebase(['apps:sdkconfig', 'ANDROID', app_id, '--out', str(out)], pid, capture=True)
        downloads[role] = out
        ok(f'{APP_NAMES[role]}：{PACKAGES[role]}')
    run([sys.executable, str(ROOT / 'tool' / 'configure_firebase.py'),
         '--host', str(downloads['host']), '--client', str(downloads['client']),
         '--database-url', state['databaseUrl']], capture=True)
    ok('已寫入 App 設定檔（config/*.json 與 google-services.json，不會上傳到 Git）')


def _secret_exists(pid: str, name: str) -> bool:
    return firebase(['functions:secrets:get', name], pid, capture=True, check=False).returncode == 0


def step_backend(state: dict) -> None:
    """寫入後端設定並產生伺服器密鑰。"""
    pid = state['project']
    (BACKEND / '.firebaserc').write_text(
        json.dumps({'projects': {'default': pid}}, indent=2) + '\n', encoding='utf-8')
    env = FUNCTIONS / f'.env.{pid}'
    env.write_text(
        '# Generated by tool/setup.py. Not committed to Git.\n'
        f'FAMILYHELPER_DATABASE_URL={state["databaseUrl"]}\n'
        f'FAMILYHELPER_STORAGE_BUCKET={state.get("storageBucket", "")}\n'
        f'TURN_URL={state.get("turnUrl", "")}\n', encoding='utf-8')
    ok('已寫入 backend/.firebaserc 與後端環境設定')

    # Random secrets: generated here, sent to Secret Manager on stdin only.
    for name in ('PAIR_PEPPER', 'TURN_SECRET'):
        if _secret_exists(pid, name):
            ok(f'{name} 已存在，保留原值')
            continue
        firebase(['functions:secrets:set', name, '--data-file=-'], pid,
                 stdin=secrets.token_urlsafe(48) + '\n', capture=True)
        ok(f'已產生 {name}')

    print()
    info('跨網路連線（例如長輩在家用 Wi‑Fi、你用行動網路）有時需要 TURN 中繼。')
    info('沒有 TURN 時，同一個 Wi‑Fi 下通常可以連線；跨網路可能失敗。')
    use_cf = confirm('要設定 Cloudflare TURN 嗎？（需要 Cloudflare 帳號，不確定就選 n）', False)
    for name, label in (('CLOUDFLARE_TURN_KEY_ID', 'Cloudflare TURN Key ID'),
                        ('CLOUDFLARE_TURN_API_TOKEN', 'Cloudflare TURN API Token')):
        if not use_cf and _secret_exists(pid, name):
            ok(f'{name} 已存在，保留原值')
            continue
        if use_cf:
            import getpass
            value = getpass.getpass(f'  ? 貼上 {label}（畫面不會顯示）：').strip()
            if not value:
                raise SetupError(f'{label} 不能空白', [])
        else:
            value = 'disabled'
        firebase(['functions:secrets:set', name, '--data-file=-'], pid,
                 stdin=value + '\n', capture=True)
    ok('TURN 設定完成' if use_cf else '先不使用 TURN（之後可重跑 --from 6 再設定）')


def step_deploy(state: dict) -> None:
    """安裝後端套件並部署到你的 Firebase。"""
    pid = state['project']
    info('安裝後端套件…')
    npm_path = shutil.which('npm')
    if not npm_path:
        raise SetupError('找不到 npm，請先安裝 Node.js。', [])
    run([npm_path, 'ci', '--no-audit', '--no-fund'], cwd=FUNCTIONS, capture=True)
    targets = 'functions,database' + (',storage' if state.get('storageBucket') else '')
    info(f'部署 {targets}（第一次大約 5–10 分鐘，可能會詢問要不要啟用 Google API，請回答 Y）')
    firebase(['deploy', '--only', targets], pid)
    ok('後端部署完成')


def step_signing(state: dict) -> None:
    """產生 APK 簽章金鑰。"""
    key = ROOT / 'android' / 'familyhelper-release.jks'
    if key.exists():
        ok('簽章金鑰已存在，沿用')
        return
    run([sys.executable, str(ROOT / 'tool' / 'create_release_key.py')], capture=True)
    ok('已產生 android/familyhelper-release.jks 與 android/key.properties')
    warn('請把這兩個檔案備份到安全的地方（例如加密隨身碟）。')
    warn('遺失後就無法更新已安裝的 App，只能解除安裝重來。')


def step_build(state: dict) -> None:
    """打包長輩版與家人版 APK。"""
    info('打包中，第一次大約需要 5–15 分鐘…')
    run([sys.executable, str(ROOT / 'tool' / 'build_apks.py')])
    ok('完成！')


STEPS = [
    ('檢查電腦環境', step_check),
    ('登入 Google', step_login),
    ('Firebase 專案', step_project),
    ('Firebase 網頁設定', step_console),
    ('註冊 Android App', step_apps),
    ('後端設定與密鑰', step_backend),
    ('部署後端', step_deploy),
    ('簽章金鑰', step_signing),
    ('打包 APK', step_build),
]


def finish() -> None:
    print()
    print(_c('1;32', '━━ 全部完成 ━━'))
    info('安裝檔在 dist/ 資料夾：')
    info('  • familyhelper-host.apk   → 裝在長輩的手機')
    info('  • familyhelper-client.apk → 裝在每位家人的手機（最多 6 位）')
    info('')
    info('接下來：')
    info('  1. 把 APK 傳到手機（LINE 檔案、Google Drive、USB 都可以），點開安裝')
    info('     （手機會問是否允許安裝未知來源的 App，請允許）')
    info('  2. 長輩手機：右上角「設定」→「產生配對碼」')
    info('  3. 家人手機：輸入名字與配對碼 → 配對')
    info('  4. 想讓家人能遠端點擊：在長輩手機「設定 → 允許遠端點擊」照指示開啟')
    info('詳細圖文說明：docs/SETUP.md')


def main() -> int:
    parser = argparse.ArgumentParser(description='FamilyHelper 一鍵設定精靈')
    parser.add_argument('--from', dest='start', type=int, metavar='N',
                        help='從第 N 步重新開始（1–%d）' % len(STEPS))
    parser.add_argument('--check', action='store_true', help='只檢查電腦環境')
    args = parser.parse_args()

    print(_c('1', 'FamilyHelper 設定精靈'))
    info('會帶你建立自己家的 Firebase 後端，並打包長輩版與家人版 App。')
    info('隨時可以按 Ctrl+C 中斷，之後重新執行會從停下的步驟繼續。')

    if args.check:
        try:
            step_check({})
        except SetupError as e:
            fail(str(e))
            return 1
        ok('環境檢查通過')
        return 0

    state = load_state()
    if args.start:
        if not 1 <= args.start <= len(STEPS):
            parser.error(f'--from 必須是 1 到 {len(STEPS)}')
        state['done'] = [n for n in state['done'] if n < args.start]
    for n, (label, fn) in enumerate(STEPS, 1):
        if n in state['done'] and n != 1:
            continue
        title(n, len(STEPS), label)
        try:
            fn(state)
        except SetupError as e:
            fail(str(e))
            for line in e.detail:
                info(_c('2', line))
            info(f'修正後重新執行：python3 tool/setup.py（會從第 {n} 步繼續）')
            save_state(state)
            return 1
        except KeyboardInterrupt:
            print()
            save_state(state)
            info(f'已中斷。重新執行會從第 {n} 步繼續。')
            return 130
        if n not in state['done']:
            state['done'].append(n)
        save_state(state)
    finish()
    return 0


if __name__ == '__main__':
    sys.exit(main())
