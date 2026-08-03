#include "BiliNetwork.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QFile>
#include <QJsonParseError>
#include <QMetaObject>
#include <QNetworkRequest>
#include <QRunnable>
#include <QThread>
#include <memory>
#include <utility>

// 注意：BiliNetwork 单例必须在 GUI/qApp 线程首次创建。
// init_plugin 可能跑在无事件循环的加载线程——那里绝不能 instance()。

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

// 合并 DASH 流的接口路径（Go 侧 /video/merge）：
// 合并请求属于下载任务的一部分，取消下载时要一并中止
const char *const kMergeRequestPath = "/video/merge";

} // namespace

BiliNetwork *BiliNetwork::s_instance = nullptr;
QMutex BiliNetwork::s_instanceMutex;

BiliNetwork *BiliNetwork::instance() {
  QMutexLocker locker(&s_instanceMutex);
  if (!s_instance) {
    // parent = qApp，自动清理。不要在非 GUI 线程调用本函数来"顺便创建"：
    // QObject 有 parent 时无法 moveToThread，QNAM 会钉死在错误线程。
    if (qApp && QThread::currentThread() != qApp->thread()) {
      qWarning() << "[BiliNet] instance() first created off GUI thread"
                 << QThread::currentThread()
                 << "— QNAM events may never dispatch. "
                    "Create it from attach_engine / QML thread instead.";
    }
    s_instance = new BiliNetwork(qApp);
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
  QList<QPointer<QNetworkReply>> repliesToAbort;
  {
    QMutexLocker locker(&m_replyMutex);
    repliesToAbort = m_downloadReplies.values();
    if (m_mergeReply) {
      repliesToAbort.append(m_mergeReply);
    }
  }

  for (const QPointer<QNetworkReply> &reply : repliesToAbort) {
    if (reply) {
      qDebug() << "[BiliNetwork] Aborting download/merge request...";
      reply->abort();
    }
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
  {
    QMutexLocker locker(&m_replyMutex);
    m_activeReplies.insert(reply);
  }
  // reply 销毁时自动摘除，避免遗漏 untrack 留下悬垂指针
  connect(reply, &QObject::destroyed, this,
          [this, reply]() { untrackReply(reply); });
}

void BiliNetwork::untrackReply(QNetworkReply *reply) {
  QMutexLocker locker(&m_replyMutex);
  m_activeReplies.remove(reply);
}

void BiliNetwork::setApiServerReady(bool ready) {
  if (m_apiServerReady == ready) {
    return;
  }
  m_apiServerReady = ready;
  if (ready) {
    flushPendingRequests();
    return;
  }

  // 关闸兜底：调用方普遍是"先关闸，再在异步回调里开闸"，只要有一条路径丢了
  // 回调（bring-up 重入、manager 被销毁等），闸门就再也打不开，且插件重启也
  // 救不回来——BiliNetwork 是跨插件生命周期存活的单例。这里兜底强制放行。
  const int generation = ++m_readyGateGeneration;
  QTimer::singleShot(READY_GATE_TIMEOUT_MS, this, [this, generation]() {
    if (m_apiServerReady || m_readyGateGeneration != generation) {
      return;
    }
    qWarning() << "[BiliNet] API ready gate timed out, force reopening";
    m_apiServerReady = true;
    flushPendingRequests();
  });
}

void BiliNetwork::flushPendingRequests() {
  if (!m_apiServerReady || m_pendingRequests.isEmpty()) {
    return;
  }
  // 分批放行避免撞自身限流：3 条/批 × 400ms => 任意 1 秒窗口 ≤ 9 条 < 10 条/秒
  const int batch = qMin(m_pendingRequests.size(), 3);
  QVector<PendingRequest> current;
  current.reserve(batch);
  for (int i = 0; i < batch; ++i) {
    current.append(m_pendingRequests.takeFirst());
  }
  for (PendingRequest &req : current) {
    get(req.path, req.params, std::move(req.onSuccess), std::move(req.onError));
  }
  if (!m_pendingRequests.isEmpty()) {
    QTimer::singleShot(400, this, [this]() { flushPendingRequests(); });
  }
}

void BiliNetwork::cancelAllRequests() {
  // 丢弃尚未发出的排队请求，不回调
  m_pendingRequests.clear();

  QList<QNetworkReply *> replies;
  {
    QMutexLocker locker(&m_replyMutex);
    // abort() 同步触发 finished，置位标志让 handleReply 静默本次取消
    m_cancelingAll = true;
    replies = m_activeReplies.values();
  }

  for (QNetworkReply *reply : replies) {
    if (reply && reply->isRunning()) {
      reply->abort();
    }
  }
  // 下一事件循环迭代复位：覆盖"内部已完成但 finished 尚在队列"的异步派发
  QTimer::singleShot(0, this, [this]() {
    QMutexLocker locker(&m_replyMutex);
    m_cancelingAll = false;
  });
  // 不在这里删除，让 finished 信号处理清理
}

void BiliNetwork::get(const QString &path, const QMap<QString, QString> &params,
                      SuccessCallback onSuccess, ErrorCallback onError,
                      int timeoutMs) {
  // 服务未就绪时先排队，就绪后自动发出
  if (!m_apiServerReady) {
    if (m_pendingRequests.size() >= MAX_PENDING_REQUESTS) {
      qWarning() << "[BiliNet] Pending queue full, rejecting:" << path;
      if (onError) {
        onError(-17, "服务启动中，请稍后重试");
      }
      return;
    }
    m_pendingRequests.append(
        {path, params, std::move(onSuccess), std::move(onError)});
    return;
  }

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

  // 全局 10s 空闲超时会截断合并等长时间无数据回流的请求，用请求级超时覆盖
  if (timeoutMs > 0) {
    request.setTransferTimeout(timeoutMs);
  }

  QNetworkReply *reply = m_nam->get(request);
  if (!reply) {
    if (onError) {
      onError(-13, "创建网络请求失败");
    }
    return;
  }

  trackReply(reply);

  // 合并请求单独跟踪：取消下载任务时要一并中止
  if (path == QLatin1String(kMergeRequestPath)) {
    QMutexLocker locker(&m_replyMutex);
    m_mergeReply = reply;
  }

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
    // 先断开 finished 侧对 timer 的引用，再排队删除，避免双重 deleteLater 竞态
    timer->disconnect();
    timer->deleteLater();
  });
  timer->start(timeoutMs > 0 ? timeoutMs : m_requestTimeout);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, onSuccess, onError, timer]() {
            timer->stop();
            timer->deleteLater();
            untrackReply(reply);
            {
              QMutexLocker locker(&m_replyMutex);
              if (m_mergeReply == reply) {
                m_mergeReply = nullptr;
              }
            }
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
    timer->disconnect();
    timer->deleteLater();
  });
  timer->start(10000);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, onSuccess, onError, timer]() {
            timer->stop();
            timer->disconnect();
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
                                std::function<void(qint64 received, qint64 total)> onProgress,
                                const QString &tag) {
  QUrl downloadUrl(url);
  if (!downloadUrl.isValid()) {
    if (onError)
      onError(-3, "无效的视频地址");
    return;
  }

  QNetworkRequest request(downloadUrl);
  applyCommonHeaders(request);
  // 弱网卡顿时 10s 空闲超时会误杀下载，改为 300s（与下方总超时 QTimer 一致）
  request.setTransferTimeout(300000);

  QNetworkReply *reply = m_nam->get(request);
  if (!reply) {
    if (onError)
      onError(-13, "创建请求失败");
    return;
  }

  // 按用途分槽记录下载任务（视频/音频流与字幕互不覆盖）
  {
    QMutexLocker locker(&m_replyMutex);
    m_downloadReplies.insert(tag, reply);
  }

  trackReply(reply);

  // 创建临时文件
  QFile *file = new QFile(targetPath, this);
  if (!file->open(QIODevice::WriteOnly)) {
    qWarning() << "[BiliNet] Failed to create temp file:" << targetPath;
    if (onError)
      onError(-15, "无法创建临时文件");

    // 清理记录
    untrackReply(reply);
    {
      QMutexLocker locker(&m_replyMutex);
      if (m_downloadReplies.value(tag) == reply) {
        m_downloadReplies.remove(tag);
      }
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

  // 在数据可读时写入文件；写失败立即中止下载
  auto writeFailed = std::make_shared<bool>(false);
  connect(reply, &QNetworkReply::readyRead, [file, reply, writeFailed]() {
    if (*writeFailed || !file || !file->isOpen() || !reply) {
        return;
    }
    if (reply->bytesAvailable() <= 0) {
        return;
    }
    const QByteArray data = reply->readAll();
    if (data.isEmpty()) {
        return;
    }
    const qint64 written = file->write(data);
    if (written != data.size() || file->error() != QFileDevice::NoError) {
        *writeFailed = true;
        qWarning() << "[BiliNet] File write failed:" << file->errorString();
        reply->abort(); // finished 中统一清理并回调 onError
    }
  });

  QPointer<QNetworkReply> safeReply(reply);
  QTimer *timer = new QTimer(this);
  timer->setSingleShot(true);
  connect(timer, &QTimer::timeout, this, [safeReply, timer]() {
    if (safeReply && safeReply->isRunning()) {
      safeReply->abort();
    }
    timer->disconnect();
    timer->deleteLater();
  });
  // 视频下载超时时间设为 5 分钟
  timer->start(300000);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, file, targetPath, onSuccess, onError, timer,
           writeFailed, tag]() {
            timer->stop();
            timer->disconnect();
            timer->deleteLater();
            untrackReply(reply);

            // 确保在 finished 信号处理结束时，清理对 reply 的跟踪
            {
                QMutexLocker locker(&m_replyMutex);
                if (m_downloadReplies.value(tag) == reply) {
                    m_downloadReplies.remove(tag);
                }
            }

            // 写入剩余数据
            if (file && file->isOpen()) {
                if (!*writeFailed && reply->bytesAvailable() > 0) {
                    const QByteArray data = reply->readAll();
                    if (!data.isEmpty()) {
                        const qint64 written = file->write(data);
                        if (written != data.size() ||
                            file->error() != QFileDevice::NoError) {
                            *writeFailed = true;
                            qWarning() << "[BiliNet] File write failed:"
                                       << file->errorString();
                        }
                    }
                }
                if (!*writeFailed && !file->flush()) {
                    *writeFailed = true;
                    qWarning() << "[BiliNet] File flush failed:"
                               << file->errorString();
                }
                file->close();
            }

            if (reply->error() == QNetworkReply::NoError && !*writeFailed) {
              if (onSuccess) {
                onSuccess(targetPath);
              }
            } else {
              // 删除失败的文件
              file->remove();
              if (*writeFailed) {
                qWarning() << "[BiliNet] Download aborted by write failure";
                if (onError) {
                  onError(-16, "写入文件失败（磁盘空间可能不足）");
                }
              } else {
                qWarning() << "[BiliNet] Download failed:"
                           << reply->errorString();
                if (onError) {
                  onError(reply->error(), reply->errorString());
                }
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

    // cancelAll 已重置状态，其引发的取消静默跳过 onError
    if (reply->error() == QNetworkReply::OperationCanceledError) {
      bool silent = false;
      {
        QMutexLocker locker(&m_replyMutex);
        silent = m_cancelingAll;
      }
      if (silent)
        return;
    }

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
