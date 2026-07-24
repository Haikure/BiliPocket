#pragma once

#include <QJsonValue>

namespace BiliJson {

inline int intValue(const QJsonValue &value, bool *ok = nullptr) {
  if (value.isDouble()) {
    if (ok) *ok = true;
    return value.toInt();
  }
  if (value.isString()) {
    bool converted = false;
    int result = value.toString().toInt(&converted);
    if (ok) *ok = converted;
    return converted ? result : 0;
  }
  if (ok) *ok = false;
  return 0;
}

}  // namespace BiliJson
