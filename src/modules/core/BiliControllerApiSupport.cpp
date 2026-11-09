#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
#include "modules/season/BiliSeasonModule.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProcess>
#include <QRegExp>
#include <QSettings>
#include <QStandardPaths>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QtGlobal>
#include <algorithm>
#include <functional>
#include <memory>

// ====== 内部辅助方法 ======

void BiliController::apiGet(const QString &path,
                            const QMap<QString, QString> &params,
                            std::function<void(const QJsonObject &)> onSuccess,
                            std::function<void(int, const QString &)> onError,
                            bool withLoading) {
  if (withLoading) {
    setIsLoading(true);
  }

  QPointer<BiliController> self(this);
  m_network->get(
      path, params,
      [self, onSuccess, withLoading](const QJsonObject &data) {
        if (!self)
          return;
        if (withLoading) {
          self->setIsLoading(false);
        }
        if (onSuccess) {
          onSuccess(data);
        }
      },
      [self, onError, withLoading](int code, const QString &msg) {
        if (!self)
          return;
        if (withLoading) {
          self->setIsLoading(false);
        }
        if (onError) {
          onError(code, msg);
        }
      });
}

void BiliController::updateAcceptQualities(const QJsonObject &data) {
  QVector<int> newAccepts;
  QJsonArray accept = data.value("accept_quality").toArray();
  for (const QJsonValue &v : accept) {
    int q = v.toInt(0);
    if (q > 0)
      newAccepts.append(q);
  }
  // 兼容 support_formats（仅保留可观看清晰度，作为补充）
  QJsonArray supportFormats = data.value("support_formats").toArray();
  for (const QJsonValue &v : supportFormats) {
    QJsonObject obj = v.toObject();
    int q = obj.value("quality").toInt(0);
    int canWatch = obj.value("can_watch_qn_reason").toInt(0);
    int limit = obj.value("limit_watch_reason").toInt(0);
    if (q > 0 && canWatch == 0 && limit == 0 && !newAccepts.contains(q)) {
      newAccepts.append(q);
    }
  }

  QJsonObject dash = data.value("dash").toObject();
  QJsonArray audioArray = dash.value("audio").toArray();
  if (!audioArray.isEmpty() && !newAccepts.contains(0)) {
    newAccepts.append(0);
  }

  setAcceptQualities(newAccepts);
}

BiliController::DashResult
BiliController::pickDashUrls(const QJsonObject &data, int requestedQuality) const {
  DashResult result;
  result.finalQuality = requestedQuality;

  QJsonObject dash = data.value("dash").toObject();
  if (dash.isEmpty()) {
    return result;
  }

  QJsonArray videoArray = dash.value("video").toArray();
  QJsonArray audioArray = dash.value("audio").toArray();

  auto pickVideoByQn = [&](int qn, bool preferAvc) -> bool {
    for (const QJsonValue &v : videoArray) {
      QJsonObject videoObj = v.toObject();
      if (videoObj.value("id").toInt(0) == qn) {
        QString codecs = videoObj.value("codecs").toString();
        if (preferAvc && !codecs.startsWith("avc")) {
          continue;
        }
        QString url = videoObj.value("base_url").toString();
        if (url.isEmpty())
          url = videoObj.value("baseUrl").toString();
        if (!url.isEmpty()) {
          result.videoUrl = url;
          result.finalQuality = qn;
          return true;
        }
      }
    }
    return false;
  };

  // 优先用户选择的清晰度（优先 AVC）
  if (!pickVideoByQn(requestedQuality, true)) {
    pickVideoByQn(requestedQuality, false);
  }

  if (result.videoUrl.isEmpty()) {
    QVector<int> qualityOrder = {16, 32, 64, 80, 112, 116, 120, 125};
    for (int qn : qualityOrder) {
      if (qn == requestedQuality)
        continue;
      if (pickVideoByQn(qn, true))
        break;
      if (pickVideoByQn(qn, false))
        break;
    }
  }

  if (!audioArray.isEmpty()) {
    QVector<int> audioOrder = {30280, 30232, 30216};
    for (int audioQn : audioOrder) {
      for (const QJsonValue &a : audioArray) {
        QJsonObject audioObj = a.toObject();
        if (audioObj.value("id").toInt(0) == audioQn) {
          QString url = audioObj.value("base_url").toString();
          if (url.isEmpty())
            url = audioObj.value("baseUrl").toString();
          if (!url.isEmpty()) {
            result.audioUrl = url;
            break;
          }
        }
      }
      if (!result.audioUrl.isEmpty())
        break;
    }
  }

  return result;
}

QString BiliController::pickMp4Url(const QJsonObject &data) const {
  QJsonArray durl = data.value("durl").toArray();
  if (durl.isEmpty())
    return "";

  QJsonObject first = durl.first().toObject();
  QString url = first.value("url").toString();
  if (url.isEmpty()) {
    QJsonArray backup = first.value("backup_url").toArray();
    if (!backup.isEmpty()) {
      url = backup.first().toString();
    }
  }
  return url;
}
