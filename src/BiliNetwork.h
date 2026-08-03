#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QMutex>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <functional>

class QNetworkRequest;

class BiliNetwork : public QObject {
  Q_OBJECT

public:
  // 回调类型定义
  using SuccessCallback = std::function<void(const QJsonObject &data)>;
  using ErrorCallback = std::function<void(int code, const QString &message)>;
  using RawCallback = std::function<void(const QByteArray &data)>;

  static BiliNetwork *instance();

  // 基础请求；timeoutMs 为 0 时使用默认超时
  void get(const QString &path, const QMap<QString, QString> &params,
           SuccessCallback onSuccess, ErrorCallback onError = nullptr,
           int timeoutMs = 0);

  // 下载图片
  void downloadImage(const QUrl &url, RawCallback onSuccess,
                     ErrorCallback onError = nullptr);

  // 下载视频到临时文件；tag 区分用途（"video"/"subtitle"），
  // 各用途独立跟踪 reply，取消时一并中止，互不覆盖。
  void downloadVideo(const QString &url, const QString &targetPath,
                     std::function<void(const QString &path)> onSuccess,
                     std::function<void(int code, const QString &msg)> onError,
                     std::function<void(qint64 received, qint64 total)> onProgress = nullptr,
                     const QString &tag = QStringLiteral("video"));

  // 获取 API 地址
  QString apiBase() const;

  // 未就绪时 get() 请求进入队列，就绪后自动发出（仅主线程调用）
  void setApiServerReady(bool ready);

  // 取消所有正在进行的请求
  Q_INVOKABLE void cancelAllRequests();
  // 单独取消视频下载
  void cancelVideoDownload();

signals:
  void networkError(const QString &message);

private:
  explicit BiliNetwork(QObject *parent = nullptr);
  ~BiliNetwork();

  // 禁止拷贝
  BiliNetwork(const BiliNetwork &) = delete;
  BiliNetwork &operator=(const BiliNetwork &) = delete;

  void handleReply(QNetworkReply *reply, SuccessCallback onSuccess,
                   ErrorCallback onError);

  // 设置 B 站请求公共头（UA / Referer / 重定向）
  void applyCommonHeaders(QNetworkRequest &request);

  bool checkRateLimit();
  void trackReply(QNetworkReply *reply);
  void untrackReply(QNetworkReply *reply);
  void flushPendingRequests();

  QNetworkAccessManager *m_nam;
  QString m_apiBase;
  int m_requestTimeout;

  // 就绪前的请求排队
  struct PendingRequest {
    QString path;
    QMap<QString, QString> params;
    SuccessCallback onSuccess;
    ErrorCallback onError;
  };
  bool m_apiServerReady = true;
  QVector<PendingRequest> m_pendingRequests;
  static constexpr int MAX_PENDING_REQUESTS = 32;
  // 关闸兜底：上游 bring-up 若因重入/销毁丢了完成回调，闸门会永远关着，
  // 表现为界面一直"加载中"且一个请求都不发。超时后强制放行。
  // 必须大于 bring-up 看门狗(45s)，否则慢启动会被提前开闸、请求白白失败。
  int m_readyGateGeneration = 0;
  static constexpr int READY_GATE_TIMEOUT_MS = 60000;

  // 请求跟踪（用于取消和防止泄漏）
  QMutex m_replyMutex;
  QSet<QNetworkReply *> m_activeReplies;
  // 下载请求按用途分槽跟踪（video/subtitle），合并请求单独跟踪；取消时一并中止
  QHash<QString, QPointer<QNetworkReply>> m_downloadReplies;
  QPointer<QNetworkReply> m_mergeReply;
  // cancelAll 期间 abort 同步触发 finished，handleReply 据此静默取消错误
  bool m_cancelingAll = false;

  // 速率限制
  QMutex m_rateMutex;
  QVector<qint64> m_requestTimestamps;
  static constexpr int MAX_REQUESTS_PER_SECOND = 10;
  static constexpr int MAX_CONCURRENT_REQUESTS = 20;

  // 大响应 JSON 解析放工作线程；小于阈值的仍同步解析，免线程调度开销
  static constexpr int JSON_ASYNC_THRESHOLD = 16 * 1024;
  QThreadPool m_jsonPool;

  static BiliNetwork *s_instance;
  static QMutex s_instanceMutex;
};
