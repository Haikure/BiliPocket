#include "BiliImageProvider.h"
#include "BiliNetwork.h"
#include <QBuffer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPainter>
#include <QPainterPath>
#include <QQuickTextureFactory>
#include <QSaveFile>
#include <QStringList>
#include <QThread>
#include <QUrl>
#include <memory>

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
constexpr const char *kRoundImagePrefix = "round/";

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

// ========== 磁盘缓存 ==========
// 键为最终下载 URL 的 SHA-1，存原始字节；圆形等后处理变体共用同一份数据。

constexpr qint64 kMaxDiskCacheBytes = 30LL * 1024 * 1024;      // 总上限 ~30MB
constexpr qint64 kMaxDiskCacheEntryBytes = 5LL * 1024 * 1024;  // 单文件上限

QString resolveDiskCacheDir() {
  // /userdisk 为持久存储，不可写时退回 /tmp（重启即失）
  const QStringList candidates = {
      QStringLiteral("/userdisk/PenMods/plugins/bili_plugin/image_cache"),
      QStringLiteral("/tmp/bili_plugin_image_cache")};
  for (const QString &path : candidates) {
    QDir dir(path);
    if ((dir.exists() || dir.mkpath(QStringLiteral("."))) &&
        QFileInfo(dir.absolutePath()).isWritable()) {
      return dir.absolutePath();
    }
  }
  return QString();
}

const QString &diskCacheDir() {
  static const QString dir = resolveDiskCacheDir(); // 线程安全的一次性初始化
  return dir;
}

QString diskCachePathForUrl(const QString &url) {
  const QString &dir = diskCacheDir();
  if (dir.isEmpty())
    return QString();
  const QByteArray hash =
      QCryptographicHash::hash(url.toUtf8(), QCryptographicHash::Sha1).toHex();
  return dir + QLatin1Char('/') + QString::fromLatin1(hash) +
         QStringLiteral(".img");
}

QByteArray readDiskCache(const QString &url) {
  const QString path = diskCachePathForUrl(url);
  if (path.isEmpty())
    return QByteArray();

  QByteArray data;
  {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
      return QByteArray();
    data = file.readAll();
  }

  if (!data.isEmpty()) {
    // 刷新 mtime，让清理近似 LRU
    QFile touch(path);
    if (touch.open(QIODevice::ReadWrite)) {
      touch.setFileTime(QDateTime::currentDateTime(),
                        QFileDevice::FileModificationTime);
    }
  }
  return data;
}

void writeDiskCache(const QString &url, const QByteArray &data) {
  if (data.isEmpty() || (qint64)data.size() > kMaxDiskCacheEntryBytes)
    return;
  const QString path = diskCachePathForUrl(url);
  if (path.isEmpty())
    return;

  // QSaveFile 原子改名，避免留下半截文件；失败静默忽略
  QSaveFile file(path);
  if (!file.open(QIODevice::WriteOnly))
    return;
  if (file.write(data) != data.size()) {
    file.cancelWriting();
    return;
  }
  file.commit();
}

void pruneDiskCache() {
  const QString &dirPath = diskCacheDir();
  if (dirPath.isEmpty())
    return;

  QDir dir(dirPath);
  // QDir::Time 为最新在前，加 Reversed 后最旧在前
  const QFileInfoList files = dir.entryInfoList(
      QDir::Files | QDir::NoSymLinks, QDir::Time | QDir::Reversed);

  qint64 total = 0;
  for (const QFileInfo &info : files)
    total += info.size();

  for (const QFileInfo &info : files) {
    if (total <= kMaxDiskCacheBytes)
      break;
    if (QFile::remove(info.absoluteFilePath()))
      total -= info.size();
  }
}

// 不用 QRunnable::create：其参数为标准库类型且实现在 Qt 库内，
// 本项目用 libc++ 而设备上的 Qt 用 libstdc++，符号对不上
class PruneDiskCacheTask final : public QRunnable {
public:
  void run() override { pruneDiskCache(); }
};

// 每线程复用 NAM：下载由线程池线程内的局部 QEventLoop 同步驱动，
// 二者同线程满足亲和性要求，复用可保持 keep-alive 与 TLS 会话
QNetworkAccessManager *threadNetworkManager() {
  thread_local std::unique_ptr<QNetworkAccessManager> nam;
  if (!nam)
    nam.reset(new QNetworkAccessManager);
  return nam.get();
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

QImage BiliImageResponse::decodeImageData(const QByteArray &data) {
  QImage image;
  if (!data.isEmpty() && isValidImageData(data))
    image.loadFromData(data);

  // 缩放超大图，避免内存峰值
  if (!image.isNull() && (image.width() > 1920 || image.height() > 1920)) {
    image = image.scaled(1920, 1920, Qt::KeepAspectRatio,
                         Qt::SmoothTransformation);
  }
  return image;
}

QImage BiliImageResponse::roundCropped(const QImage &image) {
  if (image.isNull())
    return image;

  const int side = qMin(image.width(), image.height());
  if (side <= 0)
    return QImage();

  // 裁出居中正方形后用圆形路径纹理填充；
  // setClipPath 不做抗锯齿，fillPath 才有平滑边缘
  const QRect squareRect((image.width() - side) / 2,
                         (image.height() - side) / 2, side, side);
  QImage square = image.copy(squareRect);
  if (square.format() != QImage::Format_ARGB32_Premultiplied)
    square = square.convertToFormat(QImage::Format_ARGB32_Premultiplied);

  QImage result(side, side, QImage::Format_ARGB32_Premultiplied);
  result.fill(Qt::transparent);

  QPainter painter(&result);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
  QPainterPath path;
  path.addEllipse(QRectF(0, 0, side, side));
  painter.fillPath(path, QBrush(square));
  painter.end();

  return result;
}

QImage BiliImageResponse::downloadImage(const QString &url) {
  if (m_cancelled.loadRelaxed())
    return QImage();

  QNetworkAccessManager *nam = threadNetworkManager();

  QNetworkRequest request;
  request.setUrl(QUrl(url));
  request.setRawHeader("Referer", "https://www.bilibili.com");
  request.setRawHeader("User-Agent",
                       "Mozilla/5.0 (Linux; Android 11) BiliPocket/1.0");
  request.setMaximumRedirectsAllowed(3);
  // 超时后 abort 请求并触发 finished
  request.setTransferTimeout(10000);

  QNetworkReply *reply = nam->get(request);
  if (!reply)
    return QImage();

  QEventLoop loop;

  bool aborted = false;
  constexpr qint64 maxBytes = 10 * 1024 * 1024;

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

  loop.exec(QEventLoop::ExcludeUserInputEvents);

  QImage image;
  if (!aborted && reply->error() == QNetworkReply::NoError) {
    const QByteArray data = reply->readAll();
    if ((qint64)data.size() <= maxBytes) {
      image = decodeImageData(data);
      if (!image.isNull())
        writeDiskCache(url, data);
    }
  }

  // NAM 被复用，reply 不能靠 NAM 析构清理；此处仍在 reply 所属线程内
  reply->disconnect();
  delete reply;

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

  // "round/" 为最外层前缀，可与 original/、size/WxH/ 组合
  const bool roundCrop = imageUrl.startsWith(QLatin1String(kRoundImagePrefix));
  if (roundCrop)
    imageUrl = imageUrl.mid(QString::fromLatin1(kRoundImagePrefix).size());

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
    if (roundCrop)
      m_image = roundCropped(m_image);
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

  // 3. 查磁盘缓存，未命中才下载
  QImage fetched = decodeImageData(readDiskCache(imageUrl));
  if (fetched.isNull())
    fetched = downloadImage(imageUrl);

  m_image = scaledForRequestedSize(fetched);
  if (roundCrop)
    m_image = roundCropped(m_image);

  // 4. 存内存缓存
  if (!m_image.isNull()) {
    QWriteLocker locker(m_cacheLock);
    qint64 bytes = (qint64)m_image.bytesPerLine() * m_image.height();
    int cost = qMax((int)qMin(bytes, (qint64)INT_MAX), 1024);
    // 仅缓存合理大小的图片
    if (cost < 10 * 1024 * 1024) {
      m_cache->insert(m_cacheKey, new QImage(m_image), cost);
    }
  }

  if (m_image.isNull()) {
    m_image =
        createPlaceholder(m_requestedSize.width(), m_requestedSize.height());
    if (roundCrop)
      m_image = roundCropped(m_image);
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
  // 延长空闲线程存活，避免滚动间隙丢掉每线程 NAM 的 keep-alive 连接
  m_threadPool.setExpiryTimeout(60 * 1000);
  // 清理磁盘缓存中超限的旧文件
  m_threadPool.start(new PruneDiskCacheTask);
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
