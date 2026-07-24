#pragma once

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
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

  // 基础请求
  void get(const QString &path, const QMap<QString, QString> &params,
           SuccessCallback onSuccess, ErrorCallback onError = nullptr);

  // 下载图片
  void downloadImage(const QUrl &url, RawCallback onSuccess,
                     ErrorCallback onError = nullptr);

  // 下载视频到临时文件
  void downloadVideo(const QString &url, const QString &targetPath,
                     std::function<void(const QString &path)> onSuccess,
                     std::function<void(int code, const QString &msg)> onError,
                     std::function<void(qint64 received, qint64 total)> onProgress = nullptr);

  // 获取 API 地址
  QString apiBase() const;

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

  QNetworkAccessManager *m_nam;
  QString m_apiBase;
  int m_requestTimeout;

  // 请求跟踪（用于取消和防止泄漏）
  QMutex m_replyMutex;
  QSet<QNetworkReply *> m_activeReplies;
  QPointer<QNetworkReply> m_videoDownloadReply;

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
