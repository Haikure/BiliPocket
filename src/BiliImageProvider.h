#pragma once

#include <QAtomicInt>
#include <QCache>
#include <QImage>
#include <QMutex>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QReadWriteLock>
#include <QRunnable>
#include <QThread>
#include <QThreadPool>

class BiliNetwork;

// ========== 异步图片响应类 ==========

class BiliImageResponse : public QQuickImageResponse, public QRunnable {
  Q_OBJECT
public:
  BiliImageResponse(const QString &id, const QSize &requestedSize,
                    QCache<QString, QImage> *cache, QReadWriteLock *cacheLock);

  QQuickTextureFactory *textureFactory() const override;
  void run() override;
  void cancel() override;

private:
  QString m_id;
  QSize m_requestedSize;
  QImage m_image;
  QCache<QString, QImage> *m_cache;
  QReadWriteLock *m_cacheLock;
  QAtomicInt m_cancelled;
  QString m_cacheKey;

  QImage downloadImage(const QString &url);
  QImage scaledForRequestedSize(const QImage &image) const;
  static QImage createPlaceholder(int w = 160, int h = 100);
  static bool isValidImageData(const QByteArray &data);
};

// ========== 异步图片提供者 ==========

class BiliImageProvider : public QQuickAsyncImageProvider {
public:
  explicit BiliImageProvider(BiliNetwork *network);
  ~BiliImageProvider() override;

  QQuickImageResponse *
  requestImageResponse(const QString &id, const QSize &requestedSize) override;

private:
  QPointer<BiliNetwork> m_network;

  QReadWriteLock m_cacheLock;
  QCache<QString, QImage> m_cache;

  QThreadPool m_threadPool;

  static constexpr int MAX_CACHE_COST = 20 * 1024 * 1024;
  static constexpr int MAX_CONCURRENT = 8;
};
