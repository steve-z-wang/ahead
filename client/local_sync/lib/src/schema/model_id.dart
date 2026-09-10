import 'package:uuid/uuid_value.dart';

typedef UUID = UuidValue;

abstract base class ModelId {
  const ModelId();

  Map<String, Object> get components;
}
