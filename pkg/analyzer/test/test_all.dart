// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.engine;

import 'package:unittest/unittest.dart';

import 'cancelable_future_test.dart' as cancelable_future_test;
import 'enum_test.dart' as enum_test;
import 'file_system/test_all.dart' as file_system;
import 'generated/test_all.dart' as generated;
import 'instrumentation/test_all.dart' as instrumentation;
import 'parse_compilation_unit_test.dart' as parse_compilation_unit;
import 'source/test_all.dart' as source;
import 'src/test_all.dart' as src;
import 'task/test_all.dart' as task;

/// Utility for manually running all tests.
main() {
  groupSep = ' | ';
  group('analysis engine', () {
    cancelable_future_test.main();
    enum_test.main();
    file_system.main();
    generated.main();
    instrumentation.main();
    parse_compilation_unit.main();
    source.main();
    src.main();
    task.main();
  });
}
