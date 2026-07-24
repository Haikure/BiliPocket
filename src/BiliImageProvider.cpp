#include "BiliImageProvider.h"
#include "BiliNetwork.h"
#include <QBuffer>
#include <QCoreApplication>
#include <QDebug>
#include <QEventLoop>
#include <QGuiApplication>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQuickTextureFactory>
#include <QStringList>
#include <QThread>
#include <QTimer>
#include <QUrl>

// 调试开关
#ifdef DEBUG_IMAGE_PROVIDER
#define IMG_DEBUG qDebug() << "[BiliImg]" << QThread::currentThread()
#else
#define IMG_DEBUG                                                              \
  if (0)                                                                       \
  qDebug()
#endif

namespace {

constexpr const char *kOriginalImagePrefix = "original/";
constexpr const char *kSizedImagePrefix = "size/";

bool isNumericParam(const QString &param, QLatin1Char suffix) {
  if (!param.endsWith(suffix) || param.size() <= 1)
    return false;

  bool ok = false;
  param.left(param.size() - 1).toLongLong(&ok);
  return ok;
}

QString appendBiliSizeLimitToPath(const QString &path, int maxWidth,
                                  int maxHeight) {
  const int atIndex = path.lastIndexOf(QLatin1Char('@'));
  if (atIndex < 0)
    return path + QStringLiteral("@%1w_%2h").arg(maxWidth).arg(maxHeight);

  QString params = path.mid(atIndex + 1);
  QString format;
  const QStringList formats = {
      QStringLiteral(".avg_color"), QStringLiteral(".jpeg"),
      QStringLiteral(".jpg"),       QStringLiteral(".webp"),
      QStringLiteral(".avif"),      QStringLiteral(".png")};

  for (const QString &candidate : formats) {
    if (params.endsWith(candidate, Qt::CaseInsensitive)) {
      format = params.right(candidate.size());
      params.chop(candidate.size());
      break;
    }
  }

  QStringList keptParams;
  for (const QString &param : params.split(QLatin1Char('_'), Qt::SkipEmptyParts)) {
    if (isNumericParam(param, QLatin1Char('w')) ||
        isNumericParam(param, QLatin1Char('h'))) {
      continue;
    }
    keptParams.append(param);
  }

  keptParams.append(QStringLiteral("%1w").arg(maxWidth));
  keptParams.append(QStringLiteral("%1h").arg(maxHeight));

  return path.left(atIndex + 1) + keptParams.join(QLatin1Char('_')) + format;
}

QString withBiliImageSizeLimit(const QString &urlString, int maxWidth = 320,
                               int maxHeight = 170) {
  QUrl url(urlString);
  const QString host = url.host().toLower();
  const bool isBiliImageHost =
      host == QStringLiteral("hdslb.com") ||
      host.endsWith(QStringLiteral(".hdslb.com")) ||
      host == QStringLiteral("biliimg.com") ||
      host.endsWith(QStringLiteral(".biliimg.com"));

  if (!url.isValid() || !isBiliImageHost ||
      !url.path().startsWith(QStringLiteral("/bfs/"))) {
    return urlString;
  }

  url.setPath(appendBiliSizeLimitToPath(url.path(), maxWidth, maxHeight));
  return url.toString();
}

} // namespace

// ========== BiliImageResponse 实现 ==========

BiliImageResponse::BiliImageResponse(const QString &id,
                                     const QSize &requestedSize,
                                     QCache<QString, QImage> *cache,
                                     QReadWriteLock *cacheLock)
    : m_id(id), m_requestedSize(requestedSize), m_cache(cache),
      m_cacheLock(cacheLock), m_cancelled(0), m_cacheKey(id) {
  if (m_requestedSize.width() > 0 && m_requestedSize.height() > 0) {
    m_cacheKey += QStringLiteral("@%1x%2")
                      .arg(m_requestedSize.width())
                      .arg(m_requestedSize.height());
  }
  setAutoDelete(false);
}

void BiliImageResponse::cancel() { m_cancelled.storeRelaxed(1); }

QImage BiliImageResponse::createPlaceholder(int w, int h) {
  if (w <= 0) w = 160;
  if (h <= 0) h = 100;
  QImage placeholder(w, h, QImage::Format_RGB32);
  placeholder.fill(QColor(50, 50, 50));
  return placeholder;
}

bool BiliImageResponse::isValidImageData(const QByteArray &data) {
  if (data.size() < 4)
    return false;

  const uchar *d = reinterpret_cast<const uchar *>(data.constData());

  // JPEG: FF D8 FF
  if (d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF)
    return true;

  // PNG: 89 50 4E 47
  if (d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47)
    return true;

  // GIF: 47 49 46
  if (d[0] == 'G' && d[1] == 'I' && d[2] == 'F')
    return true;

  // BMP: 42 4D
  if (d[0] == 'B' && d[1] == 'M')
    return true;

  // WebP: RIFF....WEBP
  if (data.size() >= 12 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' &&
      d[3] == 'F' && d[8] == 'W' && d[9] == 'E' && d[10] == 'B' &&
      d[11] == 'P') {
    return true;
  }

  return false;
}

QImage BiliImageResponse::scaledForRequestedSize(const QImage &image) const {
  if (image.isNull() || m_requestedSize.width() <= 0 || m_requestedSize.height() <= 0)
    return image;

  if (image.width() <= m_requestedSize.width() &&
      image.height() <= m_requestedSize.height()) {
    return image;
  }

  return image.scaled(m_requestedSize, Qt::KeepAspectRatioByExpanding,
                      Qt::SmoothTransformation);
}

QImage BiliImageResponse::downloadImage(const QString &url) {
  if (m_cancelled.loadRelaxed())
    return QImage();

  // 在当前线程创建 NAM，生命周期完全确定
  QNetworkAccessManager nam;

  QNetworkRequest request;
  request.setUrl(QUrl(url));
  request.setRawHeader("Referer", "https://www.bilibili.com");
  request.setRawHeader("User-Agent",
                       "Mozilla/5.0 (Linux; Android 11) BiliPocket/1.0");
  request.setMaximumRedirectsAllowed(3);
  request.setTransferTimeout(10000); // Qt 5.15+

  QNetworkReply *reply = nam.get(request);
  if (!reply)
    return QImage();

  QEventLoop loop;

  bool aborted = false;
  const qint64 maxBytes = 10 * 1024 * 1024;

  QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);

  QObject::connect(reply, &QNetworkReply::downloadProgress,
                   [reply, this, &aborted](qint64 received, qint64) {
                     constexpr qint64 maxBytes = 10 * 1024 * 1024;
                     if (m_cancelled.loadRelaxed()) {
                       aborted = true;
                       reply->abort();
                       return;
                     }
                     if (received > maxBytes) {
                       aborted = true;
                       reply->abort();
                     }
                   });

  // 超时保护
  QTimer timer;
  timer.setSingleShot(true);
  QObject::connect(&timer, &QTimer::timeout, [reply, &loop]() {
    reply->abort();
    loop.quit();
  });
  timer.start(10000);

  loop.exec(QEventLoop::ExcludeUserInputEvents);

  QImage image;
  if (!aborted && reply->error() == QNetworkReply::NoError) {
    QByteArray data = reply->readAll();
    if (!data.isEmpty() && data.size() <= maxBytes && isValidImageData(data)) {
      image.loadFromData(data);
    }
  }

  reply->deleteLater();

  // 缩放大图
  if (!image.isNull()) {
    if (image.width() > 1920 || image.height() > 1920) {
      image = image.scaled(1920, 1920, Qt::KeepAspectRatio,
                           Qt::SmoothTransformation);
    }
  }

  return image;
}

void BiliImageResponse::run() {
  // 1. 查缓存
  {
    QReadLocker locker(m_cacheLock);
    QImage *cached = m_cache->object(m_cacheKey);
    if (cached && !cached->isNull()) {
      m_image = *cached;
      emit finished();
      return;
    }
  }

  if (m_cancelled.loadRelaxed()) {
    m_image = createPlaceholder(m_requestedSize.width(), m_requestedSize.height());
    emit finished();
    return;
  }

  // 2. 构造 URL / 解析 base64
  QString imageUrl = m_id;
  int limitWidth = 320;
  int limitHeight = 170;
  const bool keepOriginal = imageUrl.startsWith(QLatin1String(kOriginalImagePrefix));
  if (keepOriginal) {
    imageUrl = imageUrl.mid(QString::fromLatin1(kOriginalImagePrefix).size());
  } else if (imageUrl.startsWith(QLatin1String(kSizedImagePrefix))) {
    const QString sizedImageUrl =
        imageUrl.mid(QString::fromLatin1(kSizedImagePrefix).size());
    const int slashIndex = sizedImageUrl.indexOf(QLatin1Char('/'));
    if (slashIndex > 0) {
      const QString sizeSpec = sizedImageUrl.left(slashIndex);
      const int xIndex = sizeSpec.indexOf(QLatin1Char('x'));
      if (xIndex > 0) {
        bool widthOk = false;
        bool heightOk = false;
        const int requestedWidth = sizeSpec.left(xIndex).toInt(&widthOk);
        const int requestedHeight = sizeSpec.mid(xIndex + 1).toInt(&heightOk);
        if (widthOk && heightOk && requestedWidth > 0 && requestedHeight > 0 &&
            requestedWidth <= 4096 && requestedHeight <= 4096) {
          limitWidth = requestedWidth;
          limitHeight = requestedHeight;
        }
      }
      imageUrl = sizedImageUrl.mid(slashIndex + 1);
    }
  }

  // 检查是否为 base64 data URL (格式：data:image/png;base64,xxxx)
  if (imageUrl.startsWith("data:image/")) {
    int commaPos = imageUrl.indexOf(',');
    if (commaPos > 0) {
      QString base64Data = imageUrl.mid(commaPos + 1);
      QByteArray imageData = QByteArray::fromBase64(base64Data.toUtf8());
      if (!imageData.isEmpty() && isValidImageData(imageData)) {
        m_image.loadFromData(imageData);
        m_image = scaledForRequestedSize(m_image);
      }
    }
    // 无论是否成功，都直接返回（不查缓存/不下载）
    if (m_image.isNull()) {
      m_image = createPlaceholder(m_requestedSize.width(), m_requestedSize.height());
    }
    emit finished();
    return;
  }

  // 普通 URL 处理
  int queryIndex = imageUrl.indexOf('?');
  if (queryIndex >= 0)
    imageUrl = imageUrl.left(queryIndex);

  if (imageUrl.contains('%'))
    imageUrl = QUrl::fromPercentEncoding(imageUrl.toUtf8());

  if (!imageUrl.startsWith("http://") && !imageUrl.startsWith("https://")) {
    if (imageUrl.startsWith("//"))
      imageUrl = "https:" + imageUrl;
    else {
      m_image = createPlaceholder(m_requestedSize.width(), m_requestedSize.height());
      emit finished();
      return;
    }
  }

  if (!keepOriginal)
    imageUrl = withBiliImageSizeLimit(imageUrl, limitWidth, limitHeight);

  // 3. 同步下载（在线程池线程中，不阻塞渲染）
  m_image = scaledForRequestedSize(downloadImage(imageUrl));

  const QImage placeholder =
      createPlaceholder(m_requestedSize.width(), m_requestedSize.height());

  // 4. 存缓存（仅成功时，且不是 placeholder）
  if (!m_image.isNull() && m_image != placeholder) {
    QWriteLocker locker(m_cacheLock);
    qint64 bytes = (qint64)m_image.bytesPerLine() * m_image.height();
    int cost = qMax((int)qMin(bytes, (qint64)INT_MAX), 1024);
    // 仅缓存合理大小的图片
    if (cost < 10 * 1024 * 1024) {
      m_cache->insert(m_cacheKey, new QImage(m_image), cost);
    }
  }

  if (m_image.isNull()) {
    m_image = placeholder;
  }

  emit finished();
}

QQuickTextureFactory *BiliImageResponse::textureFactory() const {
  return QQuickTextureFactory::textureFactoryForImage(m_image);
}

// ========== BiliImageProvider 实现 ==========

BiliImageProvider::BiliImageProvider(BiliNetwork *network)
    : QQuickAsyncImageProvider(), m_network(network), m_cache(MAX_CACHE_COST) {
  m_threadPool.setMaxThreadCount(MAX_CONCURRENT);
}

BiliImageProvider::~BiliImageProvider() {
  IMG_DEBUG << "Destroying...";

  m_threadPool.clear();           // 移除未开始的任务
  m_threadPool.waitForDone(5000); // 等待已运行任务完成

  // 清理缓存
  QWriteLocker locker(&m_cacheLock);
  m_cache.clear();

  IMG_DEBUG << "Destroyed";
}

QQuickImageResponse *
BiliImageProvider::requestImageResponse(const QString &id,
                                        const QSize &requestedSize) {
  auto *response =
      new BiliImageResponse(id, requestedSize, &m_cache, &m_cacheLock);

  m_threadPool.start(response);

  return response;
}
