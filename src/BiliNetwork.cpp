#include "BiliNetwork.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QFile>
#include <QJsonParseError>
#include <QMetaObject>
#include <QNetworkRequest>
#include <QRunnable>
#include <utility>

namespace {

// API 响应解析结果（可在任意线程产出，主线程消费）
struct ApiParseResult {
  bool ok = false;
  QJsonObject data;
  int errorCode = 0;
  QString errorMsg;
};

// 纯解析：只依赖入参、不触碰共享状态，可在工作线程运行
ApiParseResult parseApiResponse(const QByteArray &rawData) {
  ApiParseResult r;
  QJsonParseError parseError;
  QJsonDocument doc = QJsonDocument::fromJson(rawData, &parseError);

  if (parseError.error != QJsonParseError::NoError) {
    r.errorCode = -6;
    r.errorMsg =
        QStringLiteral("数据解析错误：%1").arg(parseError.errorString());
    return r;
  }
  if (!doc.isObject()) {
    r.errorCode = -7;
    r.errorMsg = QStringLiteral("服务器返回格式异常");
    return r;
  }

  QJsonObject root = doc.object();
  int code = root.value("code").toInt(-999);
  if (code != 0) {
    r.errorCode = code;
    r.errorMsg =
        root.value("message").toString(QStringLiteral("Unknown error"));
    return r;
  }

  r.ok = true;
  r.data = root.value("data").toObject();
  return r;
}

// 主线程分发：把解析结果转为 onSuccess / onError 调用
void dispatchApiResult(const ApiParseResult &r,
                       const BiliNetwork::SuccessCallback &onSuccess,
                       const BiliNetwork::ErrorCallback &onError) {
  if (r.ok) {
    if (onSuccess)
      onSuccess(r.data);
    return;
  }
  if (r.errorCode == -6) {
    qWarning() << "[BiliNet] JSON parse error:" << r.errorMsg;
  } else if (r.errorCode != -7) {
    qWarning() << "[BiliNet] API error:" << r.errorCode << r.errorMsg;
  }
  if (onError)
    onError(r.errorCode, r.errorMsg);
}

// 在工作线程解析大响应，完成后回主线程分发
class JsonParseRunnable : public QRunnable {
public:
  JsonParseRunnable(QByteArray data, BiliNetwork::SuccessCallback onSuccess,
                    BiliNetwork::ErrorCallback onError,
                    QPointer<BiliNetwork> net)
      : m_data(std::move(data)), m_onSuccess(std::move(onSuccess)),
        m_onError(std::move(onError)), m_net(net) {}

  void run() override {
    ApiParseResult result = parseApiResponse(m_data);
    BiliNetwork *net = m_net;
    if (!net)
      return;
    auto onSuccess = m_onSuccess;
    auto onError = m_onError;
    // context = BiliNetwork（主线程对象），其销毁会自动丢弃未决调用
    QMetaObject::invokeMethod(
        net,
        [result, onSuccess, onError]() {
          dispatchApiResult(result, onSuccess, onError);
        },
        Qt::QueuedConnection);
  }

private:
  QByteArray m_data;
  BiliNetwork::SuccessCallback m_onSuccess;
  BiliNetwork::ErrorCallback m_onError;
  QPointer<BiliNetwork> m_net;
};

} // namespace

BiliNetwork *BiliNetwork::s_instance = nullptr;
QMutex BiliNetwork::s_instanceMutex;

BiliNetwork *BiliNetwork::instance() {
  QMutexLocker locker(&s_instanceMutex);
  if (!s_instance) {
    s_instance = new BiliNetwork(qApp); // parent = QApplication，自动清理
  }
  return s_instance;
}

BiliNetwork::BiliNetwork(QObject *parent)
    : QObject(parent), m_nam(new QNetworkAccessManager(this)),
      m_apiBase("http://127.0.0.1:8000"), m_requestTimeout(10000) {
  m_nam->setTransferTimeout(m_requestTimeout);
  // JSON 解析线程池：适当提高并发，避免多个列表响应排队过久
  m_jsonPool.setMaxThreadCount(4);
}

BiliNetwork::~BiliNetwork() {
  cancelAllRequests();
  m_jsonPool.waitForDone();
}

void BiliNetwork::cancelVideoDownload() {
  QPointer<QNetworkReply> replyToAbort;
  {
    QMutexLocker locker(&m_replyMutex);
    replyToAbort = m_videoDownloadReply;
  }

  if (replyToAbort) {
    qDebug() << "[BiliNetwork] Aborting video download...";
    replyToAbort->abort();
  }
}

QString BiliNetwork::apiBase() const { return m_apiBase; }

void BiliNetwork::applyCommonHeaders(QNetworkRequest &request) {
  // 使用正常浏览器 UA，避免风控
  request.setRawHeader("User-Agent",
                       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
  request.setRawHeader("Referer", "https://www.bilibili.com");
  request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                       QNetworkRequest::NoLessSafeRedirectPolicy);
}

bool BiliNetwork::checkRateLimit() {
  QMutexLocker locker(&m_rateMutex);

  qint64 now = QDateTime::currentMSecsSinceEpoch();

  // 清理 1 秒前的时间戳
  while (!m_requestTimestamps.isEmpty() &&
         (now - m_requestTimestamps.first()) > 1000) {
    m_requestTimestamps.removeFirst();
  }

  if (m_requestTimestamps.size() >= MAX_REQUESTS_PER_SECOND) {
    qWarning() << "[BiliNet] Rate limit exceeded!";
    return false;
  }

  m_requestTimestamps.append(now);
  return true;
}

void BiliNetwork::trackReply(QNetworkReply *reply) {
  QMutexLocker locker(&m_replyMutex);
  m_activeReplies.insert(reply);
}

void BiliNetwork::untrackReply(QNetworkReply *reply) {
  QMutexLocker locker(&m_replyMutex);
  m_activeReplies.remove(reply);
}

void BiliNetwork::cancelAllRequests() {
  QList<QNetworkReply *> replies;
  {
    QMutexLocker locker(&m_replyMutex);
    replies = m_activeReplies.values();
  }

  for (QNetworkReply *reply : replies) {
    if (reply && reply->isRunning()) {
      reply->abort();
    }
  }
  // 不在这里删除，让 finished 信号处理清理
}

void BiliNetwork::get(const QString &path, const QMap<QString, QString> &params,
                      SuccessCallback onSuccess, ErrorCallback onError) {
  // 并发限制
  {
    QMutexLocker locker(&m_replyMutex);
    if (m_activeReplies.size() >= MAX_CONCURRENT_REQUESTS) {
      qWarning() << "[BiliNet] Too many concurrent requests!";
      if (onError) {
        onError(-10, "请求过于频繁，请稍后重试");
      }
      return;
    }
  }

  // 速率限制
  if (!checkRateLimit()) {
    if (onError) {
      onError(-11, "请求过于频繁");
    }
    return;
  }

  QUrl url(m_apiBase + path);
  QUrlQuery query;
  for (auto it = params.begin(); it != params.end(); ++it) {
    query.addQueryItem(it.key(), it.value());
  }
  url.setQuery(query);

  if (!url.isValid()) {
    qWarning() << "[BiliNet] Invalid URL constructed";
    if (onError) {
      onError(-12, "无效的请求地址");
    }
    return;
  }

  QNetworkRequest request(url);
  request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  applyCommonHeaders(request);

  QNetworkReply *reply = m_nam->get(request);
  if (!reply) {
    if (onError) {
      onError(-13, "创建网络请求失败");
    }
    return;
  }

  trackReply(reply);

  // 超时处理 — 使用 QPointer 防止悬空指针
  QPointer<QNetworkReply> safeReply(reply);
  QTimer *timer = new QTimer(this);
  timer->setSingleShot(true);

  connect(timer, &QTimer::timeout, this, [safeReply, timer, onError]() {
    if (safeReply && safeReply->isRunning()) {
      safeReply->abort();
      qWarning() << "[BiliNet] Request timeout!";
      // 不在这里调用 onError，让 finished 处理
    }
    timer->deleteLater();
  });
  timer->start(m_requestTimeout);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, onSuccess, onError, timer]() {
            timer->stop();
            timer->deleteLater();
            untrackReply(reply);
            handleReply(reply, onSuccess, onError);
          });
}

void BiliNetwork::downloadImage(const QUrl &url, RawCallback onSuccess,
                                ErrorCallback onError) {
  if (!url.isValid()) {
    if (onError)
      onError(-3, "无效的图片地址");
    return;
  }

  QNetworkRequest request(url);
  applyCommonHeaders(request);

  QNetworkReply *reply = m_nam->get(request);
  if (!reply) {
    if (onError)
      onError(-13, "创建请求失败");
    return;
  }

  trackReply(reply);

  // 限制下载大小
  constexpr qint64 MAX_IMAGE_SIZE = 10 * 1024 * 1024; // 10MB

  connect(reply, &QNetworkReply::downloadProgress,
          [reply](qint64 received, qint64 total) {
            Q_UNUSED(total)
            if (received > MAX_IMAGE_SIZE) {
              reply->abort();
            }
          });

  QPointer<QNetworkReply> safeReply(reply);
  QTimer *timer = new QTimer(this);
  timer->setSingleShot(true);
  connect(timer, &QTimer::timeout, this, [safeReply, timer]() {
    if (safeReply && safeReply->isRunning()) {
      safeReply->abort();
    }
    timer->deleteLater();
  });
  timer->start(10000);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, onSuccess, onError, timer]() {
            timer->stop();
            timer->deleteLater();
            untrackReply(reply);

            if (reply->error() == QNetworkReply::NoError) {
              QByteArray data = reply->readAll();
              if (data.isEmpty()) {
                if (onError)
                  onError(-4, "图片数据为空");
              } else {
                if (onSuccess)
                  onSuccess(data);
              }
            } else {
              if (onError) {
                onError(reply->error(), reply->errorString());
              }
            }
            reply->deleteLater();
          });
}

void BiliNetwork::downloadVideo(const QString &url, const QString &targetPath,
                                std::function<void(const QString &path)> onSuccess,
                                std::function<void(int code, const QString &msg)> onError,
                                std::function<void(qint64 received, qint64 total)> onProgress) {
  QUrl downloadUrl(url);
  if (!downloadUrl.isValid()) {
    if (onError)
      onError(-3, "无效的视频地址");
    return;
  }

  QNetworkRequest request(downloadUrl);
  applyCommonHeaders(request);

  QNetworkReply *reply = m_nam->get(request);
  if (!reply) {
    if (onError)
      onError(-13, "创建请求失败");
    return;
  }

  // 记录下载任务
  {
    QMutexLocker locker(&m_replyMutex);
    m_videoDownloadReply = reply;
  }

  trackReply(reply);

  // 创建临时文件
  QFile *file = new QFile(targetPath, this);
  if (!file->open(QIODevice::WriteOnly)) {
    qWarning() << "[BiliNet] Failed to create temp file:" << targetPath;
    if (onError)
      onError(-15, "无法创建临时文件");
    
    // 清理记录
    {
      QMutexLocker locker(&m_replyMutex);
      m_videoDownloadReply = nullptr;
    }
    
    reply->abort();
    reply->deleteLater();
    delete file;
    return;
  }

  // 连接下载进度
  connect(reply, &QNetworkReply::downloadProgress,
          [onProgress](qint64 received, qint64 total) {
            if (onProgress) {
              onProgress(received, total);
            }
          });

  // 在数据可读时写入文件
  connect(reply, &QNetworkReply::readyRead, [file, reply]() {
    if (file && file->isOpen() && reply) {
        if (reply->bytesAvailable() > 0) {
            QByteArray data = reply->readAll();
            if (!data.isEmpty()) {
                file->write(data);
            }
        }
    }
  });

  QPointer<QNetworkReply> safeReply(reply);
  QTimer *timer = new QTimer(this);
  timer->setSingleShot(true);
  connect(timer, &QTimer::timeout, this, [safeReply, timer]() {
    if (safeReply && safeReply->isRunning()) {
      safeReply->abort();
    }
    timer->deleteLater();
  });
  // 视频下载超时时间设为 5 分钟
  timer->start(300000);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, file, targetPath, onSuccess, onError, timer]() {
            timer->stop();
            timer->deleteLater();
            untrackReply(reply);

            // 确保在 finished 信号处理结束时，清理对 reply 的跟踪
            {
                QMutexLocker locker(&m_replyMutex);
                if (m_videoDownloadReply == reply) {
                    m_videoDownloadReply = nullptr;
                }
            }

            // 写入剩余数据
            if (file && file->isOpen()) {
                if (reply->bytesAvailable() > 0) {
                    QByteArray data = reply->readAll();
                    if (!data.isEmpty()) {
                        file->write(data);
                    }
                }
                file->close();
            }

            if (reply->error() == QNetworkReply::NoError) {
              if (onSuccess) {
                onSuccess(targetPath);
              }
            } else {
              qWarning() << "[BiliNet] Download failed:"
                         << reply->errorString();
              // 删除失败的文件
              file->remove();
              if (onError) {
                onError(reply->error(), reply->errorString());
              }
            }
            reply->deleteLater();
            file->deleteLater();
          });
}

void BiliNetwork::handleReply(QNetworkReply *reply, SuccessCallback onSuccess,
                              ErrorCallback onError) {
  if (!reply) {
    if (onError)
      onError(-99, "无效的网络回复");
    return;
  }

  // 确保 reply 最终被删除
  struct ReplyGuard {
    QNetworkReply *r;
    ~ReplyGuard() {
      if (r)
        r->deleteLater();
    }
  } guard{reply};

  // 网络层错误
  if (reply->error() != QNetworkReply::NoError) {
    QString errorMsg;
    int errorCode = reply->error();

    switch (reply->error()) {
    case QNetworkReply::OperationCanceledError:
      errorMsg = "请求已取消";
      break;
    case QNetworkReply::TimeoutError:
      errorMsg = "网络请求超时";
      break;
    case QNetworkReply::ConnectionRefusedError:
      errorMsg = "无法连接到服务器";
      break;
    case QNetworkReply::HostNotFoundError:
      errorMsg = "服务器地址未找到";
      break;
    case QNetworkReply::ContentNotFoundError:
      errorMsg = "请求的内容不存在";
      break;
    default:
      errorMsg = QString("网络错误：%1").arg(reply->errorString());
      break;
    }

    qWarning() << "[BiliNet] Error:" << errorCode << errorMsg;

    if (onError) {
      onError(errorCode, errorMsg);
    }
    // 用户主动取消/超时不再上抛全局错误，避免 UI 卡死或弹出误导错误
    if (reply->error() != QNetworkReply::OperationCanceledError &&
        reply->error() != QNetworkReply::TimeoutError) {
      emit networkError(errorMsg);
    }
    return;
  }

  // 读取数据，限制最大大小
  constexpr qint64 MAX_RESPONSE_SIZE = 50 * 1024 * 1024; // 50MB
  QByteArray rawData = reply->readAll();

  if (rawData.isEmpty()) {
    if (onError)
      onError(-5, "服务器返回空数据");
    return;
  }

  if (rawData.size() > MAX_RESPONSE_SIZE) {
    if (onError)
      onError(-14, "响应数据过大");
    return;
  }

  // JSON 解析：大响应放工作线程，避免阻塞主线程；小响应同步解析免线程调度
  if (rawData.size() <= JSON_ASYNC_THRESHOLD) {
    dispatchApiResult(parseApiResponse(rawData), onSuccess, onError);
  } else {
    m_jsonPool.start(new JsonParseRunnable(rawData, onSuccess, onError,
                                           QPointer<BiliNetwork>(this)));
  }
}
