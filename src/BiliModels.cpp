#include "BiliModels.h"
#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QSet>
#include <cmath>

namespace {

QString normalizeCommentEmoteUrl(const QString &rawUrl)
{
    QString url = rawUrl.trimmed();
    if (url.startsWith("//")) {
        return "https:" + url;
    }
    if (url.startsWith("http://")) {
        return "https://" + url.mid(7);
    }
    return url;
}

QString normalizeCommentEmoteKey(const QString &rawKey)
{
    QString key = rawKey.trimmed();
    if (key.isEmpty()) return QString();
    if (key.startsWith('[') && key.endsWith(']')) return key;
    return QString("[%1]").arg(key);
}

QVariantMap buildCommentEmoteEntry(const QString &rawKey, const QJsonObject &obj)
{
    QVariantMap entry;
    const QString key = normalizeCommentEmoteKey(rawKey);
    if (key.isEmpty()) return entry;

    const QStringList urlKeys = {
        "webp_url", "webpUrl", "webp", "gif_url", "gifUrl", "gif", "url"
    };
    QString url;
    for (const QString &urlKey : urlKeys) {
        url = normalizeCommentEmoteUrl(obj.value(urlKey).toString());
        if (!url.isEmpty()) break;
    }
    if (url.isEmpty()) return entry;

    const QJsonObject meta = obj.value("meta").toObject();
    int size = meta.value("size").toInt(obj.value("size").toInt(1));
    size = qBound(1, size, 2);
    const QString alias = meta.value("alias").toString(obj.value("alias").toString()).trimmed();

    entry.insert("text", key);
    entry.insert("url", url);
    entry.insert("size", size);
    if (!alias.isEmpty()) entry.insert("alias", alias);
    return entry;
}

void insertCommentEmoteAlias(QVariantMap &emotes, const QString &rawKey,
                             const QVariantMap &entry)
{
    const QString key = normalizeCommentEmoteKey(rawKey);
    if (key.isEmpty() || entry.isEmpty()) return;
    emotes.insert(key, entry);

    const QString bare = key.mid(1, key.size() - 2);
    if (!bare.isEmpty()) emotes.insert(bare, entry);
}

void appendCommentEmoteEntry(QVariantMap &emotes, const QString &rawKey,
                             const QJsonObject &obj)
{
    const QVariantMap entry = buildCommentEmoteEntry(rawKey, obj);
    if (entry.isEmpty()) return;

    insertCommentEmoteAlias(emotes, rawKey, entry);
    const QString alias = entry.value("alias").toString().trimmed();
    if (!alias.isEmpty()) insertCommentEmoteAlias(emotes, alias, entry);
}

void parseCommentEmoteCollection(QVariantMap &emotes, const QJsonValue &value)
{
    if (value.isObject()) {
        const QJsonObject object = value.toObject();
        if (object.contains("url") || object.contains("webp_url") || object.contains("webpUrl") ||
            object.contains("webp") || object.contains("gif_url") || object.contains("gifUrl") ||
            object.contains("gif")) {
            appendCommentEmoteEntry(emotes, object.value("text").toString(), object);
            return;
        }
        for (auto it = object.begin(); it != object.end(); ++it) {
            if (!it.value().isObject()) continue;
            QJsonObject emoteObject = it.value().toObject();
            QString key = emoteObject.value("text").toString();
            if (key.isEmpty()) key = it.key();
            appendCommentEmoteEntry(emotes, key, emoteObject);
        }
        return;
    }

    if (!value.isArray()) return;
    const QJsonArray array = value.toArray();
    for (const QJsonValue &itemValue : array) {
        if (!itemValue.isObject()) continue;
        const QJsonObject emoteObject = itemValue.toObject();
        QString key = emoteObject.value("text").toString();
        if (key.isEmpty()) key = emoteObject.value("name").toString();
        appendCommentEmoteEntry(emotes, key, emoteObject);
    }
}

QVariantMap parseCommentEmotes(const QJsonObject &content)
{
    QVariantMap emotes;
    parseCommentEmoteCollection(emotes, content.value("emote"));
    parseCommentEmoteCollection(emotes, content.value("emotes"));
    return emotes;
}

QString dynamicString(const QJsonObject &obj, const QStringList &keys)
{
    for (const QString &key : keys) {
        const QJsonValue value = obj.value(key);
        if (value.isString()) {
            const QString s = value.toString().trimmed();
            if (!s.isEmpty()) return s;
        }
    }
    return QString();
}

qint64 dynamicInt(const QJsonObject &obj, const QStringList &keys)
{
    for (const QString &key : keys) {
        const QJsonValue value = obj.value(key);
        if (value.isUndefined() || value.isNull()) continue;
        qint64 n = value.toVariant().toLongLong();
        if (n > 0) return n;
    }
    return 0;
}

qint64 dynamicCountValue(const QJsonValue &value)
{
    if (value.isDouble()) return value.toVariant().toLongLong();
    if (value.isString()) {
        QString text = value.toString().trimmed();
        text.remove(',');
        bool ok = false;
        if (text.contains(QStringLiteral("万"))) {
            const double v = text.left(text.indexOf(QStringLiteral("万"))).toDouble(&ok);
            return ok ? static_cast<qint64>(v * 10000) : 0;
        }
        if (text.contains(QStringLiteral("亿"))) {
            const double v = text.left(text.indexOf(QStringLiteral("亿"))).toDouble(&ok);
            return ok ? static_cast<qint64>(v * 100000000) : 0;
        }
        const qint64 n = text.toLongLong(&ok);
        return ok ? n : 0;
    }
    if (value.isObject()) {
        const QJsonObject obj = value.toObject();
        const qint64 count = dynamicInt(obj, {"count", "num", "value"});
        if (count > 0) return count;
        return dynamicCountValue(obj.value("text"));
    }
    return 0;
}

void appendDynamicPicture(QStringList &pictures, const QString &url)
{
    const QString trimmed = url.trimmed();
    if (!trimmed.isEmpty() && !pictures.contains(trimmed)) pictures.append(trimmed);
}

QStringList parseDynamicPictures(const QJsonArray &array, const QStringList &keys)
{
    QStringList pictures;
    for (const QJsonValue &value : array) {
        if (pictures.size() >= 9) break;
        if (value.isString()) {
            appendDynamicPicture(pictures, value.toString());
            continue;
        }
        if (!value.isObject()) continue;
        const QJsonObject obj = value.toObject();
        appendDynamicPicture(pictures, dynamicString(obj, keys));
    }
    return pictures;
}

QJsonObject dynamicMajorObject(const QJsonObject &major, const QString &key)
{
    return major.value(key).toObject();
}

QString dynamicDescText(const QJsonObject &dynamicObj)
{
    QString text = dynamicObj.value("desc").toObject().value("text").toString().trimmed();
    if (text.isEmpty()) {
        text = dynamicObj.value("major").toObject().value("opus").toObject()
                   .value("summary").toObject().value("text").toString().trimmed();
    }
    return text;
}

void fillDynamicOrig(DynamicItem &item, const QJsonObject &orig)
{
    if (orig.isEmpty()) return;
    item.isForward = true;

    const QJsonObject modules = orig.value("modules").toObject();
    const QJsonObject dynamicObj = modules.value("module_dynamic").toObject();
    const QJsonObject major = dynamicObj.value("major").toObject();
    item.origSummary = dynamicDescText(dynamicObj);

    const QJsonObject archive = dynamicMajorObject(major, "archive");
    const QJsonObject draw = dynamicMajorObject(major, "draw");
    const QJsonObject opus = dynamicMajorObject(major, "opus");
    const QJsonObject article = dynamicMajorObject(major, "article");
    const QJsonObject common = dynamicMajorObject(major, "common");

    if (!archive.isEmpty()) {
        item.origTitle = archive.value("title").toString();
        item.origCover = archive.value("cover").toString();
        item.origBvid = archive.value("bvid").toString();
        item.origAid = dynamicInt(archive, {"aid"});
    } else if (!opus.isEmpty()) {
        item.origTitle = opus.value("title").toString();
        const QStringList pics = parseDynamicPictures(opus.value("pics").toArray(), {"src", "url"});
        if (!pics.isEmpty()) item.origCover = pics.first();
        if (item.origSummary.isEmpty()) item.origSummary = opus.value("summary").toObject().value("text").toString();
    } else if (!draw.isEmpty()) {
        const QStringList pics = parseDynamicPictures(draw.value("items").toArray(), {"src", "url"});
        if (!pics.isEmpty()) item.origCover = pics.first();
    } else if (!article.isEmpty()) {
        item.origTitle = article.value("title").toString();
        const QJsonArray covers = article.value("covers").toArray();
        if (!covers.isEmpty()) item.origCover = covers.first().toString();
    } else if (!common.isEmpty()) {
        item.origTitle = common.value("title").toString();
        item.origCover = common.value("cover").toString();
    }
}

} // namespace

// ============ VideoListModel ============

VideoListModel::VideoListModel(QObject *parent)
    : QAbstractListModel(parent)
    , m_loading(false)
    , m_hasMore(true)
{
}

int VideoListModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant VideoListModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const VideoItem &item = m_items[index.row()];

    switch (role) {
    case BvidRole:      return item.bvid;
    case TitleRole:     return item.title;
    case PicRole:       return item.pic;
    case OwnerNameRole: return item.ownerName;
    case OwnerFaceRole: return item.ownerFace;
    case OwnerMidRole:  return item.ownerMid;
    case ViewsRole:     return formatCount(item.views);
    case DanmakuRole:   return formatCount(item.danmaku);
    case LikesRole:     return formatCount(item.likes);
    case DurationRole:  return item.duration;
    case CidRole:       return item.cid;
    case DescRole:      return item.desc;
    case RcmdReasonRole: return item.rcmdReason;
    case DurationTextRole: return formatDuration(item.duration);
    case PartCountRole: return item.partCount;
    case AidRole: return item.aid;
    case IsLastWatchedArcRole: return item.isLastWatchedArc;
    case LastWatchedRankRole: return item.lastWatchedRank;
    case HistoryBusinessRole: return item.historyBusiness;
    case HistoryKidRole: return item.historyKid;
    default: return QVariant();
    }
}

QHash<int, QByteArray> VideoListModel::roleNames() const
{
    return {
        {BvidRole, "bvid"},
        {TitleRole, "title"},
        {PicRole, "pic"},
        {OwnerNameRole, "ownerName"},
        {OwnerFaceRole, "ownerFace"},
        {OwnerMidRole, "ownerMid"},
        {ViewsRole, "views"},
        {DanmakuRole, "danmakuCount"},
        {LikesRole, "likes"},
        {DurationRole, "duration"},
        {CidRole, "cid"},
        {DescRole, "desc"},
        {RcmdReasonRole, "rcmdReason"},
        {DurationTextRole, "durationText"},
        {PartCountRole, "partCount"},
        {AidRole, "aid"},
        {IsLastWatchedArcRole, "isLastWatchedArc"},
        {LastWatchedRankRole, "lastWatchedRank"},
        {HistoryBusinessRole, "historyBusiness"},
        {HistoryKidRole, "historyKid"}
    };
}

int VideoListModel::count() const { return m_items.count(); }
bool VideoListModel::loading() const { return m_loading; }
bool VideoListModel::hasMore() const { return m_hasMore; }
QString VideoListModel::errorMessage() const { return m_errorMessage; }

void VideoListModel::clear()
{
    beginResetModel();
    m_items.clear();
    m_errorMessage.clear();
    endResetModel();
    emit countChanged();
    emit errorMessageChanged();
}

int VideoListModel::indexOfBvid(const QString &bvid) const
{
    if (bvid.isEmpty()) return -1;
    for (int i = 0; i < m_items.count(); ++i) {
        if (m_items.at(i).bvid == bvid) return i;
    }
    return -1;
}

int VideoListModel::indexOfAid(qint64 aid) const
{
    if (aid <= 0) return -1;
    for (int i = 0; i < m_items.count(); ++i) {
        if (m_items.at(i).aid == aid) return i;
    }
    return -1;
}

int VideoListModel::indexOfLastWatched() const
{
    for (int i = 0; i < m_items.count(); ++i) {
        if (m_items.at(i).isLastWatchedArc) return i;
    }
    return -1;
}

int VideoListModel::indexOfLastWatchedRank(int rank) const
{
    if (rank <= 0) return -1;
    for (int i = 0; i < m_items.count(); ++i) {
        if (m_items.at(i).lastWatchedRank == rank) return i;
    }
    return -1;
}

QString VideoListModel::bvidAt(int row) const
{
    if (row < 0 || row >= m_items.count()) return QString();
    return m_items.at(row).bvid;
}

void VideoListModel::removeAt(int row)
{
    if (row < 0 || row >= m_items.count()) return;
    beginRemoveRows(QModelIndex(), row, row);
    m_items.removeAt(row);
    endRemoveRows();
    emit countChanged();
}

void VideoListModel::appendItems(const QVector<VideoItem> &items)
{
    if (items.isEmpty()) return;

    beginInsertRows(QModelIndex(), m_items.count(),
                    m_items.count() + items.count() - 1);
    m_items.append(items);
    endInsertRows();
    emit countChanged();
}

void VideoListModel::prependItems(const QVector<VideoItem> &items)
{
    if (items.isEmpty()) return;

    beginInsertRows(QModelIndex(), 0, items.count() - 1);
    m_items = items + m_items;
    endInsertRows();
    emit countChanged();
}

void VideoListModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}

void VideoListModel::setHasMore(bool hasMore)
{
    if (m_hasMore != hasMore) {
        m_hasMore = hasMore;
        emit hasMoreChanged();
    }
}

void VideoListModel::setErrorMessage(const QString &msg)
{
    if (m_errorMessage != msg) {
        m_errorMessage = msg;
        emit errorMessageChanged();
    }
}

QString VideoListModel::formatDuration(int seconds)
{
    if (seconds <= 0) return "00:00";
    int h = seconds / 3600;
    int m = (seconds % 3600) / 60;
    int s = seconds % 60;
    if (h > 0) {
        return QString("%1:%2:%3")
            .arg(h)
            .arg(m, 2, 10, QChar('0'))
            .arg(s, 2, 10, QChar('0'));
    }
    return QString("%1:%2")
        .arg(m, 2, 10, QChar('0'))
        .arg(s, 2, 10, QChar('0'));
}

QString VideoListModel::formatCount(qint64 count)
{
    if (count < 0) return "0";
    if (count < 10000) return QString::number(count);
    double wan = count / 10000.0;
    if (wan < 10000) {
        return QString("%1 万").arg(wan, 0, 'f', 1);
    }
    double yi = count / 100000000.0;
    return QString("%1 亿").arg(yi, 0, 'f', 1);
}

VideoItem VideoListModel::parseVideoItem(const QJsonObject &obj)
{
    VideoItem item;
    item.bvid = obj.value("bvid").toString();
    item.title = obj.value("title").toString();
    item.pic = obj.value("pic").toString();
    if (item.pic.isEmpty()) item.pic = obj.value("cover").toString();
    item.desc = obj.value("desc").toString();

    // duration 可能是数字字符串，或 mm:ss / hh:mm:ss
    auto parseDurationString = [](const QString &durationStr) -> int {
        QString s = durationStr.trimmed();
        if (s.contains(':')) {
            QStringList parts = s.split(':');
            if (parts.size() == 2) {
                return parts[0].toInt() * 60 + parts[1].toInt();
            } else if (parts.size() == 3) {
                return parts[0].toInt() * 3600 + parts[1].toInt() * 60 + parts[2].toInt();
            }
            return 0;
        }
        return s.toInt();
    };

    if (obj.value("duration").isString()) {
        item.duration = parseDurationString(obj.value("duration").toString());
    } else {
        item.duration = obj.value("duration").toInt();
    }

    if (item.duration <= 0 && obj.value("length").isString()) {
        item.duration = parseDurationString(obj.value("length").toString());
    }

    item.cid = obj.value("cid").toVariant().toLongLong();
    item.pubdate = obj.value("pubdate").toVariant().toLongLong();

    QJsonObject cursorAttr = obj.value("cursor_attr").toObject();
    item.isLastWatchedArc = cursorAttr.value("is_last_watched_arc").toVariant().toBool();
    item.lastWatchedRank = cursorAttr.value("rank").toVariant().toInt();

    // 分P数量：不同列表接口字段名不完全一致，统一收敛到 partCount。
    int videos = obj.value("videos").toVariant().toInt();
    if (videos <= 0) videos = obj.value("page_count").toVariant().toInt();
    if (videos <= 0) videos = obj.value("pages_count").toVariant().toInt();
    if (videos <= 0) videos = obj.value("part_count").toVariant().toInt();
    if (videos <= 0) videos = obj.value("parts").toVariant().toInt();
    if (videos > 0) {
        item.partCount = videos;
    } else {
        // 有些接口返回 pages 数组或 pages 数值
        QJsonArray pages = obj.value("pages").toArray();
        if (!pages.isEmpty()) {
            item.partCount = pages.size();
        } else {
            int pagesCount = obj.value("pages").toVariant().toInt();
            if (pagesCount > 0) item.partCount = pagesCount;
        }
    }

    QJsonObject owner = obj.value("owner").toObject();
    item.ownerName = owner.value("name").toString();
    if (item.ownerName.isEmpty()) item.ownerName = obj.value("author").toString();
    item.ownerFace = owner.value("face").toString();
    item.ownerMid = owner.value("mid").toVariant().toLongLong();

    QSet<qint64> staffMids;
    QJsonArray staffArray = obj.value("staff").toArray();
    item.staff.reserve(staffArray.size() + 1);
    for (const QJsonValue &staffValue : staffArray) {
        if (!staffValue.isObject()) continue;
        QJsonObject staffObj = staffValue.toObject();
        VideoStaffItem staff;
        staff.mid = staffObj.value("mid").toVariant().toLongLong();
        staff.name = staffObj.value("name").toString();
        staff.face = staffObj.value("face").toString();
        staff.title = staffObj.value("title").toString();
        if (staff.title.isEmpty()) staff.title = staffObj.value("role").toString();
        if (staff.mid <= 0 || staff.name.isEmpty() || staffMids.contains(staff.mid)) continue;
        staffMids.insert(staff.mid);
        item.staff.append(staff);
    }
    if (!item.staff.isEmpty() && item.ownerMid > 0 && !staffMids.contains(item.ownerMid)) {
        VideoStaffItem ownerStaff;
        ownerStaff.mid = item.ownerMid;
        ownerStaff.name = item.ownerName;
        ownerStaff.face = item.ownerFace;
        item.staff.prepend(ownerStaff);
    }

    QJsonObject stat = obj.value("stat").toObject();
    item.views = stat.value("view").toVariant().toLongLong();
    item.danmaku = stat.value("danmaku").toVariant().toLongLong();
    item.likes = stat.value("like").toVariant().toLongLong();
    item.coins = stat.value("coin").toVariant().toLongLong();
    item.favorites = stat.value("favorite").toVariant().toLongLong();
    item.replies = stat.value("reply").toVariant().toLongLong();

    auto parseCountString = [](const QString &s) -> qint64 {
        QString t = s;
        t.remove(',');
        if (t.contains("万")) {
            bool ok = false;
            double v = t.left(t.indexOf("万")).toDouble(&ok);
            return ok ? static_cast<qint64>(v * 10000) : 0;
        }
        if (t.contains("亿")) {
            bool ok = false;
            double v = t.left(t.indexOf("亿")).toDouble(&ok);
            return ok ? static_cast<qint64>(v * 100000000) : 0;
        }
        bool ok = false;
        qint64 v = t.toLongLong(&ok);
        return ok ? v : 0;
    };

    // 搜索结果常用字段: play / video_review / view
    if (item.views <= 0) {
        if (obj.value("play").isString()) {
            item.views = parseCountString(obj.value("play").toString());
        } else {
            item.views = obj.value("play").toVariant().toLongLong();
        }
    }
    if (item.views <= 0) {
        item.views = obj.value("view").toVariant().toLongLong();
    }
    if (item.danmaku <= 0) {
        item.danmaku = obj.value("video_review").toVariant().toLongLong();
    }

    QJsonObject rcmd = obj.value("rcmd_reason").toObject();
    item.rcmdReason = rcmd.value("content").toString();

    return item;
}

// ============ CommentListModel ============

CommentListModel::CommentListModel(QObject *parent)
    : QAbstractListModel(parent)
    , m_loading(false)
    , m_totalCount(0)
{
}

int CommentListModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant CommentListModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const CommentItem &item = m_items[index.row()];

    switch (role) {
    case RpidRole:     return item.rpid;
    case UserNameRole: return item.userName;
    case UserMidRole:  return item.mid;
    case AvatarRole:   return item.avatar;
    case LevelRole:    return item.level;
    case ContentRole:  return item.content;
    case EmotesRole:   return item.emotes;
    case PicturesRole: return item.pictures;
    case LikesRole:    return item.likes;
    case RcountRole:   return item.rcount;
    case CtimeRole:    return item.ctime;
    case CtimeTextRole: return formatTime(item.ctime);
    case IsVipRole:    return item.isVip;
    case IsTopRole:    return item.isTop;
    case LikedRole:    return item.liked;
    default: return QVariant();
    }
}

QHash<int, QByteArray> CommentListModel::roleNames() const
{
    return {
        {RpidRole, "rpid"},
        {UserNameRole, "userName"},
        {UserMidRole, "mid"},
        {AvatarRole, "avatar"},
        {LevelRole, "level"},
        {ContentRole, "content"},
        {EmotesRole, "emotes"},
        {PicturesRole, "pictures"},
        {LikesRole, "likes"},
        {RcountRole, "rcount"},
        {CtimeRole, "ctime"},
        {CtimeTextRole, "ctimeText"},
        {IsVipRole, "isVip"},
        {IsTopRole, "isTop"},
        {LikedRole, "liked"}
    };
}

int CommentListModel::count() const { return m_items.count(); }
bool CommentListModel::loading() const { return m_loading; }
int CommentListModel::totalCount() const { return m_totalCount; }
QString CommentListModel::errorMessage() const { return m_errorMessage; }

void CommentListModel::clear()
{
    beginResetModel();
    m_items.clear();
    m_errorMessage.clear();
    endResetModel();
    emit countChanged();
    emit errorMessageChanged();
}

void CommentListModel::appendItems(const QVector<CommentItem> &items)
{
    if (items.isEmpty()) return;

    QSet<qint64> existingRpids;
    existingRpids.reserve(m_items.size() + items.size());
    for (const CommentItem &item : m_items) {
        if (item.rpid > 0) existingRpids.insert(item.rpid);
    }

    QVector<CommentItem> uniqueItems;
    uniqueItems.reserve(items.size());
    for (const CommentItem &item : items) {
        if (item.rpid > 0 && existingRpids.contains(item.rpid)) continue;
        if (item.rpid > 0) existingRpids.insert(item.rpid);
        uniqueItems.append(item);
    }

    if (uniqueItems.isEmpty()) return;

    beginInsertRows(QModelIndex(), m_items.count(),
                    m_items.count() + uniqueItems.count() - 1);
    m_items.append(uniqueItems);
    endInsertRows();
    emit countChanged();
}

void CommentListModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}

void CommentListModel::setTotalCount(int total)
{
    if (m_totalCount != total) {
        m_totalCount = total;
        emit totalCountChanged();
    }
}

void CommentListModel::setErrorMessage(const QString &msg)
{
    if (m_errorMessage != msg) {
        m_errorMessage = msg;
        emit errorMessageChanged();
    }
}

bool CommentListModel::setLikeState(qint64 rpid, bool liked)
{
    for (int row = 0; row < m_items.size(); ++row) {
        CommentItem &item = m_items[row];
        if (item.rpid != rpid) continue;
        if (item.liked == liked) return true;
        item.liked = liked;
        item.likes = qMax<qint64>(0, item.likes + (liked ? 1 : -1));
        const QModelIndex changed = index(row, 0);
        emit dataChanged(changed, changed, {LikesRole, LikedRole});
        return true;
    }
    return false;
}

CommentItem CommentListModel::parseCommentItem(const QJsonObject &obj)
{
    CommentItem item;
    item.rpid = obj.value("rpid").toVariant().toLongLong();
    item.ctime = obj.value("ctime").toVariant().toLongLong();
    item.likes = obj.value("like").toVariant().toLongLong();
    item.liked = obj.value("action").toVariant().toInt() == 1;
    item.rcount = obj.value("rcount").toVariant().toLongLong();

    QJsonObject member = obj.value("member").toObject();
    item.userName = member.value("uname").toString();
    item.mid = member.value("mid").toVariant().toLongLong();
    item.avatar = member.value("avatar").toString();

    QJsonObject levelInfo = member.value("level_info").toObject();
    item.level = levelInfo.value("current_level").toInt();

    QJsonObject vip = member.value("vip").toObject();
    item.isVip = (vip.value("vipStatus").toInt() == 1);

    QJsonObject content = obj.value("content").toObject();
    item.content = content.value("message").toString();
    item.emotes = parseCommentEmotes(content);

    QJsonArray pictures = content.value("pictures").toArray();
    for (const QJsonValue &pv : pictures) {
        if (pv.isObject()) {
            QString img = pv.toObject().value("img_src").toString();
            if (!img.isEmpty()) item.pictures.append(img);
        } else if (pv.isString()) {
            QString img = pv.toString();
            if (!img.isEmpty()) item.pictures.append(img);
        }
    }

    item.isTop = obj.value("is_top").toInt(0) == 1 || obj.value("is_top").toBool(false);

    return item;
}

QString CommentListModel::formatTime(qint64 timestamp)
{
    QDateTime dt = QDateTime::fromSecsSinceEpoch(timestamp);
    QDateTime now = QDateTime::currentDateTime();
    qint64 diff = now.toSecsSinceEpoch() - timestamp;

    if (diff < 60) return "刚刚";
    if (diff < 3600) return QString("%1 分钟前").arg(diff / 60);
    if (diff < 86400) return QString("%1 小时前").arg(diff / 3600);
    if (diff < 2592000) return QString("%1 天前").arg(diff / 86400);

    return dt.toString("yyyy-MM-dd");
}

// ============ CommentReplyListModel ============

CommentReplyListModel::CommentReplyListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int CommentReplyListModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant CommentReplyListModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const CommentReplyItem &item = m_items[index.row()];

    switch (role) {
    case RpidRole: return item.rpid;
    case UserNameRole: return item.userName;
    case UserMidRole: return item.mid;
    case AvatarRole: return item.avatar;
    case LevelRole: return item.level;
    case ContentRole: return item.content;
    case EmotesRole: return item.emotes;
    case PicturesRole: return item.pictures;
    case LikesRole: return item.likes;
    case CtimeRole: return item.ctime;
    case CtimeTextRole: return CommentListModel::formatTime(item.ctime);
    case IsVipRole: return item.isVip;
    case LikedRole: return item.liked;
    default: return QVariant();
    }
}

QHash<int, QByteArray> CommentReplyListModel::roleNames() const
{
    return {
        {RpidRole, "rpid"},
        {UserNameRole, "userName"},
        {UserMidRole, "mid"},
        {AvatarRole, "avatar"},
        {LevelRole, "level"},
        {ContentRole, "content"},
        {EmotesRole, "emotes"},
        {PicturesRole, "pictures"},
        {LikesRole, "likes"},
        {CtimeRole, "ctime"},
        {CtimeTextRole, "ctimeText"},
        {IsVipRole, "isVip"},
        {LikedRole, "liked"}
    };
}

int CommentReplyListModel::count() const { return m_items.count(); }
int CommentReplyListModel::totalCount() const { return m_totalCount; }
bool CommentReplyListModel::loading() const { return m_loading; }
QString CommentReplyListModel::errorMessage() const { return m_errorMessage; }

void CommentReplyListModel::clear()
{
    beginResetModel();
    m_items.clear();
    m_errorMessage.clear();
    m_totalCount = 0;
    endResetModel();
    emit countChanged();
    emit totalCountChanged();
    emit errorMessageChanged();
}

void CommentReplyListModel::setItems(const QVector<CommentReplyItem> &items)
{
    beginResetModel();
    m_items = items;
    endResetModel();
    emit countChanged();
}

void CommentReplyListModel::appendItems(const QVector<CommentReplyItem> &items)
{
    if (items.isEmpty()) return;
    beginInsertRows(QModelIndex(), m_items.count(), m_items.count() + items.count() - 1);
    m_items.append(items);
    endInsertRows();
    emit countChanged();
}

void CommentReplyListModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}

void CommentReplyListModel::setErrorMessage(const QString &msg)
{
    if (m_errorMessage != msg) {
        m_errorMessage = msg;
        emit errorMessageChanged();
    }
}

void CommentReplyListModel::setTotalCount(int total)
{
    if (m_totalCount != total) {
        m_totalCount = total;
        emit totalCountChanged();
    }
}

bool CommentReplyListModel::setLikeState(qint64 rpid, bool liked)
{
    for (int row = 0; row < m_items.size(); ++row) {
        CommentReplyItem &item = m_items[row];
        if (item.rpid != rpid) continue;
        if (item.liked == liked) return true;
        item.liked = liked;
        item.likes = qMax<qint64>(0, item.likes + (liked ? 1 : -1));
        const QModelIndex changed = index(row, 0);
        emit dataChanged(changed, changed, {LikesRole, LikedRole});
        return true;
    }
    return false;
}

CommentReplyItem CommentReplyListModel::parseCommentReplyItem(const QJsonObject &obj)
{
    CommentReplyItem item;
    item.rpid = obj.value("rpid").toVariant().toLongLong();
    item.ctime = obj.value("ctime").toVariant().toLongLong();
    item.likes = obj.value("like").toVariant().toLongLong();
    item.liked = obj.value("action").toVariant().toInt() == 1;

    QJsonObject member = obj.value("member").toObject();
    item.userName = member.value("uname").toString();
    item.mid = member.value("mid").toVariant().toLongLong();
    item.avatar = member.value("avatar").toString();

    QJsonObject levelInfo = member.value("level_info").toObject();
    item.level = levelInfo.value("current_level").toInt();

    QJsonObject vip = member.value("vip").toObject();
    item.isVip = (vip.value("vipStatus").toInt() == 1);

    QJsonObject content = obj.value("content").toObject();
    item.content = content.value("message").toString();
    item.emotes = parseCommentEmotes(content);

    QJsonArray pictures = content.value("pictures").toArray();
    for (const QJsonValue &pv : pictures) {
        if (pv.isObject()) {
            QString img = pv.toObject().value("img_src").toString();
            if (!img.isEmpty()) item.pictures.append(img);
        } else if (pv.isString()) {
            QString img = pv.toString();
            if (!img.isEmpty()) item.pictures.append(img);
        }
    }

    return item;
}

// ============ HotSearchModel ============

HotSearchModel::HotSearchModel(QObject *parent)
    : QAbstractListModel(parent)
    , m_loading(false)
{
}

int HotSearchModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant HotSearchModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const HotSearchItem &item = m_items[index.row()];

    switch (role) {
    case KeywordRole: return item.keyword;
    case IconRole:    return item.icon;
    case PositionRole: return item.position;
    default: return QVariant();
    }
}

QHash<int, QByteArray> HotSearchModel::roleNames() const
{
    return {
        {KeywordRole, "keyword"},
        {IconRole, "icon"},
        {PositionRole, "position"}
    };
}

int HotSearchModel::count() const { return m_items.count(); }
bool HotSearchModel::loading() const { return m_loading; }

void HotSearchModel::clear()
{
    beginResetModel();
    m_items.clear();
    endResetModel();
    emit countChanged();
}

void HotSearchModel::setItems(const QVector<HotSearchItem> &items)
{
    beginResetModel();
    m_items = items;
    endResetModel();
    emit countChanged();
}

void HotSearchModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}

// ============ DynamicListModel ============

DynamicListModel::DynamicListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int DynamicListModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant DynamicListModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const DynamicItem &item = m_items[index.row()];

    switch (role) {
    case IdStrRole: return item.idStr;
    case TypeRole: return item.type;
    case VisibleRole: return item.visible;
    case AuthorNameRole: return item.authorName;
    case AuthorFaceRole: return item.authorFace;
    case AuthorMidRole: return item.authorMid;
    case PubActionRole: return item.pubAction;
    case PubTimeRole: return item.pubTime;
    case PubTsRole: return item.pubTs;
    case TextRole: return item.text;
    case IsForwardRole: return item.isForward;
    case OrigSummaryRole: return item.origSummary;
    case OrigTitleRole: return item.origTitle;
    case OrigCoverRole: return item.origCover;
    case OrigBvidRole: return item.origBvid;
    case OrigAidRole: return item.origAid;
    case MajorTypeRole: return item.majorType;
    case MajorTitleRole: return item.majorTitle;
    case MajorCoverRole: return item.majorCover;
    case MajorBvidRole: return item.majorBvid;
    case MajorAidRole: return item.majorAid;
    case MajorDurationTextRole: return item.majorDurationText;
    case PicturesRole: return item.pictures;
    case RepostCountRole: return item.repostCount;
    case CommentCountRole: return item.commentCount;
    case LikeCountRole: return item.likeCount;
    case RepostCountTextRole: return VideoListModel::formatCount(item.repostCount);
    case CommentCountTextRole: return VideoListModel::formatCount(item.commentCount);
    case LikeCountTextRole: return VideoListModel::formatCount(item.likeCount);
    case CommentOidRole: return item.commentOid;
    case CommentTypeRole: return item.commentType;
    case IsVideoRole: return item.isVideo;
    case IsImageRole: return item.isImage;
    case IsArticleRole: return item.isArticle;
    case IsLiveRole: return item.isLive;
    default: return QVariant();
    }
}

QHash<int, QByteArray> DynamicListModel::roleNames() const
{
    return {
        {IdStrRole, "idStr"},
        {TypeRole, "type"},
        {VisibleRole, "visible"},
        {AuthorNameRole, "authorName"},
        {AuthorFaceRole, "authorFace"},
        {AuthorMidRole, "authorMid"},
        {PubActionRole, "pubAction"},
        {PubTimeRole, "pubTime"},
        {PubTsRole, "pubTs"},
        {TextRole, "text"},
        {IsForwardRole, "isForward"},
        {OrigSummaryRole, "origSummary"},
        {OrigTitleRole, "origTitle"},
        {OrigCoverRole, "origCover"},
        {OrigBvidRole, "origBvid"},
        {OrigAidRole, "origAid"},
        {MajorTypeRole, "majorType"},
        {MajorTitleRole, "majorTitle"},
        {MajorCoverRole, "majorCover"},
        {MajorBvidRole, "majorBvid"},
        {MajorAidRole, "majorAid"},
        {MajorDurationTextRole, "majorDurationText"},
        {PicturesRole, "pictures"},
        {RepostCountRole, "repostCount"},
        {CommentCountRole, "commentCount"},
        {LikeCountRole, "likeCount"},
        {RepostCountTextRole, "repostCountText"},
        {CommentCountTextRole, "commentCountText"},
        {LikeCountTextRole, "likeCountText"},
        {CommentOidRole, "commentOid"},
        {CommentTypeRole, "commentType"},
        {IsVideoRole, "isVideo"},
        {IsImageRole, "isImage"},
        {IsArticleRole, "isArticle"},
        {IsLiveRole, "isLive"}
    };
}

int DynamicListModel::count() const { return m_items.count(); }
bool DynamicListModel::loading() const { return m_loading; }
bool DynamicListModel::hasMore() const { return m_hasMore; }
QString DynamicListModel::errorMessage() const { return m_errorMessage; }

void DynamicListModel::clear()
{
    beginResetModel();
    m_items.clear();
    m_errorMessage.clear();
    endResetModel();
    emit countChanged();
    emit errorMessageChanged();
}

void DynamicListModel::appendItems(const QVector<DynamicItem> &items)
{
    if (items.isEmpty()) return;

    QSet<QString> existing;
    existing.reserve(m_items.size());
    for (const DynamicItem &item : m_items) {
        if (!item.idStr.isEmpty()) existing.insert(item.idStr);
    }

    QVector<DynamicItem> filtered;
    filtered.reserve(items.size());
    for (const DynamicItem &item : items) {
        if (!item.idStr.isEmpty() && existing.contains(item.idStr)) continue;
        if (!item.idStr.isEmpty()) existing.insert(item.idStr);
        filtered.append(item);
    }
    if (filtered.isEmpty()) return;

    beginInsertRows(QModelIndex(), m_items.count(), m_items.count() + filtered.count() - 1);
    m_items.append(filtered);
    endInsertRows();
    emit countChanged();
}

void DynamicListModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}

void DynamicListModel::setHasMore(bool hasMore)
{
    if (m_hasMore != hasMore) {
        m_hasMore = hasMore;
        emit hasMoreChanged();
    }
}

void DynamicListModel::setErrorMessage(const QString &msg)
{
    if (m_errorMessage != msg) {
        m_errorMessage = msg;
        emit errorMessageChanged();
    }
}

DynamicItem DynamicListModel::parseDynamicItem(const QJsonObject &obj)
{
    DynamicItem item;
    item.idStr = obj.value("id_str").toString();
    item.type = obj.value("type").toString();
    item.visible = obj.value("visible").toBool(true);

    const QJsonObject basic = obj.value("basic").toObject();
    item.commentOid = dynamicString(basic, {"comment_id_str", "comment_id"});
    if (item.commentOid.isEmpty()) {
        const qint64 numericCommentOid = dynamicInt(basic, {"comment_id_str", "comment_id"});
        if (numericCommentOid > 0) item.commentOid = QString::number(numericCommentOid);
    }
    item.commentType = static_cast<int>(dynamicInt(basic, {"comment_type"}));

    const QJsonObject modules = obj.value("modules").toObject();
    const QJsonObject author = modules.value("module_author").toObject();
    item.authorName = author.value("name").toString();
    item.authorFace = author.value("face").toString();
    item.authorMid = dynamicInt(author, {"mid"});
    item.pubAction = author.value("pub_action").toString();
    item.pubTime = author.value("pub_time").toString();
    item.pubTs = dynamicInt(author, {"pub_ts"});

    const QJsonObject dynamicObj = modules.value("module_dynamic").toObject();
    item.text = dynamicDescText(dynamicObj);

    const QJsonObject major = dynamicObj.value("major").toObject();
    item.majorType = major.value("type").toString();

    const QJsonObject archive = dynamicMajorObject(major, "archive");
    const QJsonObject ugcSeason = dynamicMajorObject(major, "ugc_season");
    const QJsonObject draw = dynamicMajorObject(major, "draw");
    const QJsonObject opus = dynamicMajorObject(major, "opus");
    const QJsonObject article = dynamicMajorObject(major, "article");
    const QJsonObject common = dynamicMajorObject(major, "common");
    const QJsonObject pgc = dynamicMajorObject(major, "pgc");
    const QJsonObject live = dynamicMajorObject(major, "live");
    const QJsonObject liveRcmd = dynamicMajorObject(major, "live_rcmd");

    const QJsonObject videoObj = !archive.isEmpty() ? archive : ugcSeason;
    if (!videoObj.isEmpty()) {
        item.majorTitle = videoObj.value("title").toString();
        item.majorCover = videoObj.value("cover").toString();
        item.majorBvid = videoObj.value("bvid").toString();
        item.majorAid = dynamicInt(videoObj, {"aid"});
        item.majorDurationText = videoObj.value("duration_text").toString();
        item.isVideo = !item.majorBvid.isEmpty();
    } else if (!opus.isEmpty()) {
        item.majorTitle = opus.value("title").toString();
        item.pictures = parseDynamicPictures(opus.value("pics").toArray(), {"src", "url"});
        if (item.text.isEmpty()) item.text = opus.value("summary").toObject().value("text").toString();
        if (!item.pictures.isEmpty()) item.majorCover = item.pictures.first();
        item.isImage = !item.pictures.isEmpty();
    } else if (!draw.isEmpty()) {
        item.pictures = parseDynamicPictures(draw.value("items").toArray(), {"src", "url"});
        if (!item.pictures.isEmpty()) item.majorCover = item.pictures.first();
        item.isImage = !item.pictures.isEmpty();
    } else if (!article.isEmpty()) {
        item.majorTitle = article.value("title").toString();
        item.majorCover = article.value("cover").toString();
        if (item.majorCover.isEmpty()) {
            const QJsonArray covers = article.value("covers").toArray();
            if (!covers.isEmpty()) item.majorCover = covers.first().toString();
        }
        item.isArticle = true;
    } else if (!pgc.isEmpty()) {
        item.majorTitle = pgc.value("title").toString();
        item.majorCover = pgc.value("cover").toString();
        item.isVideo = false;
    } else if (!live.isEmpty()) {
        item.majorTitle = live.value("title").toString();
        item.majorCover = live.value("cover").toString();
        item.isLive = true;
    } else if (!liveRcmd.isEmpty()) {
        item.isLive = true;
    } else if (!common.isEmpty()) {
        item.majorTitle = common.value("title").toString();
        item.majorCover = common.value("cover").toString();
    }

    if (item.majorTitle.isEmpty() && !item.text.isEmpty()) {
        item.majorTitle = item.text.left(48);
    }

    const QJsonObject stat = modules.value("module_stat").toObject();
    item.repostCount = dynamicCountValue(stat.value("forward"));
    if (item.repostCount <= 0) item.repostCount = dynamicCountValue(stat.value("repost"));
    item.commentCount = dynamicCountValue(stat.value("comment"));
    item.likeCount = dynamicCountValue(stat.value("like"));

    fillDynamicOrig(item, obj.value("orig").toObject());
    return item;
}

// ============ SearchResultModel ============

SearchResultModel::SearchResultModel(QObject *parent)
    : VideoListModel(parent)
{
}

QString SearchResultModel::keyword() const { return m_keyword; }

void SearchResultModel::setKeyword(const QString &keyword)
{
    if (m_keyword != keyword) {
        m_keyword = keyword;
        emit keywordChanged();
    }
}

void SearchResultModel::clear()
{
    VideoListModel::clear(); // 调用基类的 clear
    setKeyword("");          // 清空关键词
}

// ============ VideoPartListModel ============

VideoPartListModel::VideoPartListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int VideoPartListModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant VideoPartListModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const VideoPartItem &item = m_items[index.row()];

    switch (role) {
    case CidRole:      return item.cid;
    case PageRole:     return item.page;
    case PartRole:     return item.part;
    case DurationRole: return item.duration;
    case DurationTextRole: return VideoListModel::formatDuration(item.duration);
    default: return QVariant();
    }
}

QHash<int, QByteArray> VideoPartListModel::roleNames() const
{
    return {
        {CidRole, "cid"},
        {PageRole, "page"},
        {PartRole, "part"},
        {DurationRole, "duration"},
        {DurationTextRole, "durationText"}
    };
}

int VideoPartListModel::count() const { return m_items.count(); }

QVector<VideoPartItem> VideoPartListModel::items() const { return m_items; }

void VideoPartListModel::clear()
{
    if (m_items.isEmpty()) return;
    beginResetModel();
    m_items.clear();
    endResetModel();
    emit countChanged();
}

void VideoPartListModel::setItems(const QVector<VideoPartItem> &items)
{
    beginResetModel();
    m_items = items;
    endResetModel();
    emit countChanged();
}

VideoPartItem VideoPartListModel::parseVideoPartItem(const QJsonObject &obj)
{
    VideoPartItem item;
    item.cid = obj.value("cid").toVariant().toLongLong();
    item.page = obj.value("page").toInt();
    item.part = obj.value("part").toString();
    item.duration = obj.value("duration").toInt();
    return item;
}

// ============ FavoriteFolderModel ============

FavoriteFolderModel::FavoriteFolderModel(QObject *parent)
    : QAbstractListModel(parent)
    , m_loading(false)
{
}

int FavoriteFolderModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant FavoriteFolderModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();

    const FavoriteFolderItem &item = m_items[index.row()];

    switch (role) {
    case IdRole: return item.id;
    case FidRole: return item.fid;
    case TitleRole: return item.title;
    case CoverRole: return item.cover;
    case MediaCountRole: return item.mediaCount;
    case IntroRole: return item.intro;
    case AttrRole: return item.attr;
    default: return QVariant();
    }
}

QHash<int, QByteArray> FavoriteFolderModel::roleNames() const
{
    return {
        {IdRole, "id"},
        {FidRole, "fid"},
        {TitleRole, "title"},
        {CoverRole, "cover"},
        {MediaCountRole, "mediaCount"},
        {IntroRole, "intro"},
        {AttrRole, "attr"}
    };
}

int FavoriteFolderModel::count() const { return m_items.count(); }

bool FavoriteFolderModel::loading() const { return m_loading; }

void FavoriteFolderModel::clear()
{
    beginResetModel();
    m_items.clear();
    endResetModel();
    emit countChanged();
}

void FavoriteFolderModel::setItems(const QVector<FavoriteFolderItem> &items)
{
    beginResetModel();
    m_items = items;
    endResetModel();
    emit countChanged();
}

void FavoriteFolderModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}

void FavoriteFolderModel::updateCover(qint64 id, const QString &cover)
{
    if (cover.isEmpty()) return;
    for (int i = 0; i < m_items.size(); ++i) {
        if (m_items[i].id == id || m_items[i].fid == id) {
            if (m_items[i].cover == cover) return;
            m_items[i].cover = cover;
            QModelIndex idx = index(i, 0);
            emit dataChanged(idx, idx, {CoverRole});
            return;
        }
    }
}

FavoriteFolderItem FavoriteFolderModel::parseFavoriteFolderItem(const QJsonObject &obj)
{
    FavoriteFolderItem item;
    item.id = obj.value("id").toVariant().toLongLong();
    item.fid = obj.value("fid").toVariant().toLongLong();
    if (item.id == 0) item.id = item.fid;
    if (item.fid == 0) item.fid = item.id;
    item.title = obj.value("title").toString();
    item.cover = obj.value("cover").toString();
    item.mediaCount = obj.value("media_count").toInt();
    item.intro = obj.value("intro").toString();
    item.attr = obj.value("attr").toInt();
    return item;
}

// ============ UpSeasonListModel ============

UpSeasonListModel::UpSeasonListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int UpSeasonListModel::rowCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return m_items.count();
}

QVariant UpSeasonListModel::data(const QModelIndex &index, int role) const
{
    if (index.row() < 0 || index.row() >= m_items.count())
        return QVariant();
    const UpSeasonItem &item = m_items[index.row()];
    switch (role) {
    case SeasonIdRole: return item.seasonId;
    case NameRole:     return item.name;
    case CoverRole:    return item.cover;
    case TotalRole:    return item.total;
    case IsSeriesRole: return item.isSeries;
    default: return QVariant();
    }
}

QHash<int, QByteArray> UpSeasonListModel::roleNames() const
{
    return {
        {SeasonIdRole, "seasonId"},
        {NameRole, "name"},
        {CoverRole, "cover"},
        {TotalRole, "total"},
        {IsSeriesRole, "isSeries"}
    };
}

void UpSeasonListModel::clear()
{
    if (m_items.isEmpty()) return;
    beginResetModel();
    m_items.clear();
    endResetModel();
    emit countChanged();
}

void UpSeasonListModel::setItems(const QVector<UpSeasonItem> &items)
{
    beginResetModel();
    m_items = items;
    endResetModel();
    emit countChanged();
}

void UpSeasonListModel::setLoading(bool loading)
{
    if (m_loading != loading) {
        m_loading = loading;
        emit loadingChanged();
    }
}
