#include "modules/login/BiliLoginModule.h"

#include "BiliController.h"
#include "BiliNetwork.h"
#include "modules/feed/BiliFeedModule.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProcess>
#include <QStringList>
#include <QTimer>
#include <QUrl>

static const int SMS_LOGIN_PORT = 8666;
static const char *SMS_PULL_PATH = "/pull";
static const qint64 LOGIN_INFO_CACHE_TTL_MS = 60 * 1000;

static qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

static bool isFresh(qint64 updatedAtMs, qint64 now) {
  return updatedAtMs > 0 && now - updatedAtMs >= 0 && now - updatedAtMs < LOGIN_INFO_CACHE_TTL_MS;
}

BiliLoginModule::BiliLoginModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

bool BiliLoginModule::smsLoginRunning() const {
  return m_controller && m_controller->m_smsPolling;
}

QString BiliLoginModule::smsLoginLastError() const {
  return m_controller ? m_controller->m_smsLastError : QString();
}

void BiliLoginModule::refreshUserInfo() {
  BiliController *controller = m_controller;
  if (!controller || !controller->m_loggedIn || controller->m_userId <= 0) return;
  refreshLoginInfo();
  fetchUserInfo(controller->m_userId);
}

void BiliLoginModule::refreshUserInfoIfStale() {
  BiliController *controller = m_controller;
  if (!controller || !controller->m_loggedIn || controller->m_userId <= 0) return;

  const qint64 now = nowMs();
  if (!controller->m_loginInfoRefreshPending &&
      !isFresh(controller->m_loginInfoUpdatedAtMs, now)) {
    refreshLoginInfo();
  }
  if (!controller->m_userInfoRefreshPending &&
      !isFresh(controller->m_userInfoUpdatedAtMs, now)) {
    fetchUserInfo(controller->m_userId);
  }
}

void BiliLoginModule::generateQrcode() {
  BiliController *controller = m_controller;
  if (!controller) return;

  startSmsLogin();
  controller->setIsLoading(true);

  QPointer<BiliController> self(controller);

  controller->m_network->get(
      "/qrcode/generate", {},
      [self](const QJsonObject &data) {
        if (!self)
          return;

        self->m_qrcodeUrl = data.value("qrcode").toString();
        self->m_qrcodeKey = data.value("qrcode_key").toString();
        emit self->qrcodeChanged();
        self->setIsLoading(false);
      },
      [self](int code, const QString &msg) {
        Q_UNUSED(code)
        if (!self)
          return;

        self->setIsLoading(false);
        emit self->toastMessage(QString("获取二维码失败：%1").arg(msg));
      });
}

void BiliLoginModule::pollQrcode() {
  BiliController *controller = m_controller;
  if (!controller) return;

  if (controller->m_qrcodeKey.isEmpty()) {
    emit controller->toastMessage("请先获取二维码");
    return;
  }

  if (controller->m_loggedIn) {
    return;
  }

  QMap<QString, QString> params;
  params["qrcode_key"] = controller->m_qrcodeKey;

  QPointer<BiliController> self(controller);

  controller->m_network->get(
      "/qrcode/poll", params,
      [self](const QJsonObject &data) {
        if (!self)
          return;

        QJsonObject dataObj = data.value("data").toObject();
        if (dataObj.isEmpty()) {
          dataObj = data;
        }

        int code = dataObj.value("code").toInt(-1);
        qDebug() << "[BiliController] pollQrcode response, code=" << code;

        switch (code) {
        case 0: {
          qDebug() << "[BiliController] QR login confirmed";
          self->m_loginModule->checkLoginStatus();
          break;
        }
        case 86038:
          qDebug() << "[BiliController] QR code expired";
          emit self->qrcodeNeedRefresh();
          emit self->toastMessage("二维码已过期，请刷新");
          break;
        case 86090:
          break;
        case 86101:
          break;
        default:
          qDebug() << "[BiliController] Unknown login code:" << code;
          emit self->toastMessage("登录状态未知");
          break;
        }
      },
      [self](int code, const QString &msg) {
        Q_UNUSED(code)
        if (!self)
          return;
        qDebug() << "[BiliController] pollQrcode error:" << msg;
        emit self->toastMessage(QString("轮询失败：%1").arg(msg));
      });
}

void BiliLoginModule::startSmsLogin() {
  BiliController *controller = m_controller;
  if (!controller) return;

  if (controller->m_loggedIn) return;
  if (controller->m_smsPolling) return;

  if (!controller->m_smsNam) {
    controller->m_smsNam = new QNetworkAccessManager(controller);
  }

  QStringList candidates;
  candidates << QDir::current().filePath("bili-sms");
  candidates << QCoreApplication::applicationDirPath() + "/bili-sms";
  candidates << QStringLiteral("/userdisk/PenMods/plugins/bili_plugin/bili-sms");

  QString execPath;
  for (const QString &c : candidates) {
    if (QFile::exists(c)) { execPath = c; break; }
  }

  if (!execPath.isEmpty()) {
    QFile f(execPath);
    if (!(f.permissions() & QFile::ExeUser)) {
      f.setPermissions(f.permissions() | QFile::ExeUser | QFile::ExeGroup | QFile::ExeOther);
    }

    bool ok = QProcess::startDetached(execPath, QStringList(), QFileInfo(execPath).absolutePath());
    if (!ok) {
      controller->m_smsLastError = QString("启动 bili-sms 失败：%1").arg(execPath);
      emit controller->toastMessage(controller->m_smsLastError);
    }
  } else {
    controller->m_smsLastError = "未找到 bili-sms 可执行文件（将继续尝试轮询 8666/pull）";
    qDebug() << "[BiliController]" << controller->m_smsLastError;
  }

  if (!controller->m_smsPollTimer) {
    controller->m_smsPollTimer = new QTimer(controller);
    controller->m_smsPollTimer->setInterval(2000);
    controller->m_smsPollTimer->setSingleShot(false);
    QObject::connect(controller->m_smsPollTimer, &QTimer::timeout, this, &BiliLoginModule::pollSmsLogin);
  }

  controller->m_smsPolling = true;
  controller->m_smsImporting = false;
  controller->m_smsPollTimer->start();
}

void BiliLoginModule::stopSmsLogin() {
  BiliController *controller = m_controller;
  if (!controller) return;

  controller->m_smsPolling = false;
  controller->m_smsImporting = false;
  if (controller->m_smsPollTimer) controller->m_smsPollTimer->stop();
}

void BiliLoginModule::pollSmsLogin() {
  BiliController *controller = m_controller;
  if (!controller) return;

  if (!controller->m_smsPolling || controller->m_loggedIn) return;
  if (controller->m_smsImporting) return;
  if (!controller->m_smsNam) controller->m_smsNam = new QNetworkAccessManager(controller);

  QUrl url(QString("http://127.0.0.1:%1%2").arg(SMS_LOGIN_PORT).arg(SMS_PULL_PATH));
  QNetworkRequest req(url);
  req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");

  QNetworkReply *reply = controller->m_smsNam->get(req);
  if (!reply) return;

  QPointer<BiliController> self(controller);
  QObject::connect(reply, &QNetworkReply::finished, controller, [self, reply]() {
    if (!self) { if (reply) reply->deleteLater(); return; }

    const int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();
    reply->deleteLater();

    if (httpStatus == 404) {
      return;
    }
    if (httpStatus < 200 || httpStatus >= 300) {
      self->m_smsLastError = QString("短信登录服务异常：HTTP %1").arg(httpStatus);
      qDebug() << "[BiliController]" << self->m_smsLastError;
      return;
    }

    QJsonParseError pe;
    QJsonDocument doc = QJsonDocument::fromJson(body, &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject()) {
      self->m_smsLastError = "短信登录 /pull 返回非JSON";
      return;
    }

    QJsonObject obj = doc.object();
    QString refreshToken = obj.value("refresh_token").toString();
    QJsonObject cookies = obj.value("cookies").toObject();
    QString sessdata = cookies.value("SESSDATA").toString();
    QString biliJct = cookies.value("bili_jct").toString();
    QString buvid3 = cookies.value("buvid3").toString();
    QString dedeUserID = cookies.value("DedeUserID").toString();
    QString dedeCkMd5 = cookies.value("DedeUserID__ckMd5").toString();

    if (sessdata.isEmpty()) {
      self->m_smsLastError = "短信登录 cookies 缺少 SESSDATA";
      return;
    }

    self->m_smsImporting = true;

    QUrl importUrl(QString("%1/login/import").arg(self->m_network->apiBase()));
    QNetworkRequest importReq(importUrl);
    importReq.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");

    QJsonObject payload;
    payload.insert("SESSDATA", sessdata);
    if (!biliJct.isEmpty()) payload.insert("bili_jct", biliJct);
    if (!buvid3.isEmpty()) payload.insert("buvid3", buvid3);
    if (!dedeUserID.isEmpty()) payload.insert("DedeUserID", dedeUserID);
    if (!dedeCkMd5.isEmpty()) payload.insert("DedeUserID__ckMd5", dedeCkMd5);
    if (!refreshToken.isEmpty()) payload.insert("refresh_token", refreshToken);

    QNetworkReply *importReply = self->m_smsNam->post(importReq, QJsonDocument(payload).toJson(QJsonDocument::Compact));
    if (!importReply) { self->m_smsImporting = false; return; }

    QObject::connect(importReply, &QNetworkReply::finished, self, [self, importReply]() {
      if (!self) { if (importReply) importReply->deleteLater(); return; }

      const int st = importReply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
      importReply->deleteLater();

      self->m_smsImporting = false;

      if (st < 200 || st >= 300) {
        self->m_smsLastError = QString("导入短信登录 cookies 失败：HTTP %1").arg(st);
        return;
      }

      if (self->m_loginModule) self->m_loginModule->stopSmsLogin();

      {
        QProcess pgrep;
        pgrep.start("pgrep", QStringList() << "-f" << "bili-sms");
        if (pgrep.waitForFinished(1500) && pgrep.exitCode() == 0) {
          QString out = QString::fromLocal8Bit(pgrep.readAllStandardOutput()).trimmed();
          QStringList pids = out.split('\n', Qt::SkipEmptyParts);
          for (const QString &pid : pids) {
            QProcess::startDetached("kill", QStringList() << "-TERM" << pid);
          }
        }
      }

      if (self->m_loginModule) self->m_loginModule->checkLoginStatus();
    });
  });
}

void BiliLoginModule::checkLoginStatus() {
  BiliController *controller = m_controller;
  if (!controller) return;

  if (controller->m_loginInfoRefreshPending) return;
  controller->m_loginInfoRefreshPending = true;

  QPointer<BiliController> self(controller);

  controller->m_network->get(
      "/login/info", {},
      [self](const QJsonObject &data) {
        if (!self)
          return;

        qDebug() << "[BiliController] checkLoginStatus response:"
                 << QJsonDocument(data).toJson();

        qint64 mid = data.value("mid").toVariant().toLongLong();
        self->m_loginInfoRefreshPending = false;
        if (mid <= 0) {
          self->clearLocalLoginState();
          emit self->toastMessage("未登录，请先扫码登录");
          return;
        }

        const bool interactiveLogin = !self->m_loggedIn && !self->m_qrcodeKey.isEmpty();
        self->m_loggedIn = true;
        self->m_userName = data.value("name").toString();
        if (self->m_userName.isEmpty()) {
          self->m_userName = data.value("uname").toString();
        }
        self->m_userFace = data.value("face").toString();
        self->m_userId = mid;

        QJsonObject levelInfo = data.value("level_info").toObject();
        self->m_userLevel = levelInfo.value("current_level").toInt(0);
        self->m_userExp = levelInfo.value("current_exp").toInt(0);
        self->m_userExpMin = levelInfo.value("current_min").toInt(0);
        self->m_userExpNext = levelInfo.value("next_exp").toInt(0);

        self->m_userCoins = data.value("money").toDouble(0);

        self->m_userIsVip = data.value("vipStatus").toInt(0) == 1;
        QJsonObject vipLabel = data.value("vip_label").toObject();
        self->m_userVipLabel = vipLabel.value("text").toString();
        self->m_loginInfoUpdatedAtMs = nowMs();

        emit self->loginStateChanged();
        if (interactiveLogin) {
          emit self->qrcodeLoginSuccess();
          emit self->toastMessage("登录成功！");
        }
        // 不再登录成功后自动刷新推荐和用户详情，避免启动/登录阶段连发多请求。
        // 需要详情时由页面显式调用 refreshUserInfo()/fetchUserInfo()。
      },
      [self](int code, const QString &msg) {
        if (!self)
          return;
        self->m_loginInfoRefreshPending = false;

        qDebug() << "[BiliController] checkLoginStatus error, code:" << code
                 << "msg:" << msg;

        if (code == 401 || code == -101 || code == -401) {
          qDebug() << "[BiliController] Session expired (code=" << code << ")";
          self->clearLocalLoginState();
          emit self->toastMessage("登录已过期，请重新登录");
        } else {
          qDebug() << "[BiliController] checkLoginStatus failed (network), keeping local session:"
                   << msg;
          if (self->m_loggedIn) {
            emit self->toastMessage("登录状态验证失败，请稍后重试");
          }
        }
      });
}

void BiliLoginModule::refreshLoginInfo() {
  BiliController *controller = m_controller;
  if (!controller || !controller->m_loggedIn) return;
  if (controller->m_loginInfoRefreshPending) return;
  controller->m_loginInfoRefreshPending = true;

  QPointer<BiliController> self(controller);

  controller->m_network->get(
      "/login/info", {},
      [self](const QJsonObject &data) {
        if (!self) return;

        qint64 mid = data.value("mid").toVariant().toLongLong();
        self->m_loginInfoRefreshPending = false;
        if (mid <= 0) {
          self->clearLocalLoginState();
          emit self->toastMessage("登录已过期，请重新登录");
          return;
        }

        self->m_loggedIn = true;
        self->m_userName = data.value("name").toString();
        if (self->m_userName.isEmpty()) {
          self->m_userName = data.value("uname").toString();
        }
        self->m_userFace = data.value("face").toString();
        self->m_userId = mid;

        QJsonObject levelInfo = data.value("level_info").toObject();
        self->m_userLevel = levelInfo.value("current_level").toInt(0);
        self->m_userExp = levelInfo.value("current_exp").toInt(0);
        self->m_userExpMin = levelInfo.value("current_min").toInt(0);
        self->m_userExpNext = levelInfo.value("next_exp").toInt(0);

        self->m_userCoins = data.value("money").toDouble(0);
        self->m_userIsVip = data.value("vipStatus").toInt(0) == 1;
        QJsonObject vipLabel = data.value("vip_label").toObject();
        self->m_userVipLabel = vipLabel.value("text").toString();
        self->m_loginInfoUpdatedAtMs = nowMs();

        emit self->loginStateChanged();
      },
      [self](int code, const QString &msg) {
        if (!self) return;
        self->m_loginInfoRefreshPending = false;
        if (code == 401 || code == -101 || code == -401) {
          self->clearLocalLoginState();
          emit self->toastMessage("登录已过期，请重新登录");
          return;
        }
        qDebug() << "[BiliController] refreshLoginInfo failed:" << msg;
      });
}

void BiliLoginModule::fetchUserInfo(qint64 mid) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (mid <= 0)
    return;
  if (controller->m_userInfoRefreshPending) return;
  controller->m_userInfoRefreshPending = true;

  QPointer<BiliController> self(controller);
  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);

  controller->m_network->get(
      "/user/info", params,
      [self, mid](const QJsonObject &data) {
        if (!self) {
          return;
        }
        self->m_userInfoRefreshPending = false;
        if (!self->m_loggedIn || self->m_userId != mid)
          return;

        QJsonObject dataObj = data.value("data").toObject();
        if (dataObj.isEmpty()) {
          dataObj = data;
        }

        qDebug() << "[BiliController] fetchUserInfo response:"
                 << QJsonDocument(dataObj).toJson();

        auto toIntSafe = [](const QJsonValue &v) -> int {
          if (v.isDouble()) return v.toInt();
          if (v.isString()) return v.toString().toInt();
          return 0;
        };

        int fans = toIntSafe(dataObj.value("fans"));
        if (fans <= 0) fans = toIntSafe(dataObj.value("follower"));
        if (fans <= 0) {
          QJsonObject statObj = dataObj.value("stat").toObject();
          fans = toIntSafe(statObj.value("follower"));
        }

        int following = toIntSafe(dataObj.value("following"));
        if (following <= 0) {
          QJsonObject statObj = dataObj.value("stat").toObject();
          following = toIntSafe(statObj.value("following"));
        }

        self->m_userFans = fans;
        self->m_userFollowing = following;
        self->m_userSign = dataObj.value("sign").toString();
        self->m_userInfoUpdatedAtMs = nowMs();

        emit self->loginStateChanged();
        qDebug() << "[BiliController] User info updated:"
                 << "fans=" << self->m_userFans
                 << "following=" << self->m_userFollowing;
      },
      [self](int code, const QString &msg) {
        if (!self)
          return;
        self->m_userInfoRefreshPending = false;
        if (code == -101 || code == -401 || code == 401) {
          self->clearLocalLoginState();
          emit self->toastMessage("登录已过期，请重新登录");
          return;
        }
        qDebug() << "[BiliController] fetchUserInfo failed:" << msg;
      });
}

void BiliLoginModule::logout() {
  BiliController *controller = m_controller;
  if (!controller) return;

  stopSmsLogin();

  if (controller->m_network) {
    controller->m_network->cancelAllRequests();
  }

  QPointer<BiliController> self(controller);
  auto doLocalLogout = [self]() {
    if (!self) return;
    self->clearLocalLoginState();
    emit self->toastMessage("已退出登录");
  };

  if (controller->m_network) {
    controller->m_network->get(
        "/logout", {},
        [doLocalLogout](const QJsonObject &) { doLocalLogout(); },
        [doLocalLogout](int, const QString &) { doLocalLogout(); });
  } else {
    doLocalLogout();
  }
}
