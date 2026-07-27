#pragma once

#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliNetwork.h"

#include <QJsonObject>
#include <QMap>
#include <QPointer>
#include <QString>
#include <utility>

// 通用列表请求骨架：请求 -> accept 过期检查 -> 线程池 parse -> 主线程 apply，
// 出错走 fail；controller 存活检查由骨架完成。BiliNetwork::get 在排队溢出/
// 并发超限/限流时会同步调用 onError，此时 fail 也是同步执行。

namespace BiliListFetch {

// 请求通道：Network -> network()->get；Api/ApiWithLoading -> apiGet(withLoading)
enum class Via {
  Network,
  Api,
  ApiWithLoading,
};

// Accept: bool(BiliController *self)
// Parse:  Result(const QJsonObject &data)   —— 线程池中执行，不得访问 QObject
// Apply:  void(BiliController *self, Result result)
// Fail:   void(BiliController *self, int code, const QString &msg)
template <typename Accept, typename Parse, typename Apply, typename Fail>
void fetchParsed(BiliController *controller, Via via, const QString &path,
                 const QMap<QString, QString> &params, Accept accept,
                 Parse parse, Apply apply, Fail fail) {
  QPointer<BiliController> self(controller);

  auto onSuccess = [self, accept = std::move(accept), parse = std::move(parse),
                    apply = std::move(apply)](const QJsonObject &data) {
    if (!self || !accept(self.data()))
      return;
    biliRunInWorker(
        self, [data, parse]() { return parse(data); },
        [self, apply](auto result) {
          if (!self)
            return;
          apply(self.data(), std::move(result));
        });
  };

  auto onError = [self, fail = std::move(fail)](int code, const QString &msg) {
    if (!self)
      return;
    fail(self.data(), code, msg);
  };

  switch (via) {
  case Via::Network:
    controller->network()->get(path, params, std::move(onSuccess),
                               std::move(onError));
    break;
  case Via::Api:
    controller->apiGet(path, params, std::move(onSuccess), std::move(onError),
                       false);
    break;
  case Via::ApiWithLoading:
    controller->apiGet(path, params, std::move(onSuccess), std::move(onError),
                       true);
    break;
  }
}

// 不做额外过期检查
inline bool acceptAlways(BiliController *) { return true; }

} // namespace BiliListFetch
