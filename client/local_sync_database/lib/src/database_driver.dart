import 'database.dart';

abstract interface class DatabaseDriver {
  Future<Database> open();
}
