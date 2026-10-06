// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
// Explicit entry points prevent accidentally installing a client as a host.
import 'package:flutter/material.dart';

void main() => runApp(
  const MaterialApp(
    home: Scaffold(
      body: Center(child: Text('請使用 main_host.dart 或 main_client.dart 打包')),
    ),
  ),
);
