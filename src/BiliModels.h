#pragma once

#include <QObject>
#include <QAbstractListModel>
#include <QJsonObject>
#include <QJsonArray>
#include <QVector>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// ============ 数据结构 ============

struct VideoStaffItem {
    qint64 mid = 0;
    QString name;
    QString face;
    QString title;
};

struct VideoItem {
    qint64 aid = 0;
    QString bvid;
    QString title;
    QString pic;       // 封面 URL
    QString ownerName;
    QString ownerFace;
    qint64 ownerMid = 0;
    qint64 views = 0;
    qint64 danmaku = 0;
    qint64 likes = 0;
    qint64 coins = 0;
    qint64 favorites = 0;
    qint64 replies = 0;
    int duration = 0;    // 秒
    qint64 cid = 0;
    QString desc;
    QString rcmdReason;
    qint64 pubdate = 0;   // 发布时间（秒级时间戳）
    int partCount = 1;    // 分P数量，默认为1
    bool isLastWatchedArc = false;
    int lastWatchedRank = 0;
    QString historyBusiness;
    qint64 historyKid = 0;
    QVector<VideoStaffItem> staff;
};

struct CommentItem {
    qint64 rpid = 0;
    qint64 mid = 0;
    QString userName;
    QString avatar;
    int level = 0;
    QString content;
    QVariantMap emotes;
    QStringList pictures;
    qint64 likes = 0;
    bool liked = false;
    qint64 rcount = 0;
    qint64 ctime = 0;
    bool isVip = false;
    bool isTop = false;
};

struct CommentReplyItem {
    qint64 rpid = 0;
    qint64 mid = 0;
    QString userName;
    QString avatar;
    int level = 0;
    QString content;
    QVariantMap emotes;
    QStringList pictures;
    qint64 likes = 0;
    bool liked = false;
    qint64 ctime = 0;
    bool isVip = false;
};

struct HotSearchItem {
    QString keyword;
    QString icon;
    int position = 0;
};

struct VideoPartItem {
    qint64 cid = 0;
    int page = 0;
    QString part;
    int duration = 0;
};

struct FavoriteFolderItem {
    qint64 id = 0;
    qint64 fid = 0;
    QString title;
    QString cover;
    int mediaCount = 0;
    QString intro;
    int attr = 0;
};

struct DynamicItem {
    QString idStr;
    QString type;
    bool visible = true;

    QString authorName;
    QString authorFace;
    qint64 authorMid = 0;
    QString pubAction;
    QString pubTime;
    qint64 pubTs = 0;

    QString text;
    bool isForward = false;
    QString origSummary;
    QString origTitle;
    QString origCover;
    QString origBvid;
    qint64 origAid = 0;

    QString majorType;
    QString majorTitle;
    QString majorCover;
    QString majorBvid;
    qint64 majorAid = 0;
    QString majorDurationText;
    QStringList pictures;

    qint64 repostCount = 0;
    qint64 commentCount = 0;
    qint64 likeCount = 0;
    QString commentOid;
    int commentType = 0;

    bool isVideo = false;
    bool isImage = false;
    bool isArticle = false;
    bool isLive = false;
};

// UP 主合集/系列条目
struct UpSeasonItem {
    qint64 seasonId = 0;
    QString name;
    QString cover;
    int total = 0;
    bool isSeries = false; // false: 合集(seasons)，true: 系列(series)
};

// ============ Model 基类 ============

class VideoListModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY hasMoreChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorMessageChanged)

public:
    enum Roles {
        BvidRole = Qt::UserRole + 1,
        TitleRole,
        PicRole,
        OwnerNameRole,
        OwnerFaceRole,
        OwnerMidRole,
        ViewsRole,
        DanmakuRole,
        LikesRole,
        DurationRole,
        CidRole,
        DescRole,
        RcmdReasonRole,
        DurationTextRole,
        PartCountRole,
        AidRole,
        IsLastWatchedArcRole,
        LastWatchedRankRole,
        HistoryBusinessRole,
        HistoryKidRole
    };
    Q_ENUM(Roles)

    explicit VideoListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    bool loading() const;
    bool hasMore() const;
    QString errorMessage() const;

    Q_INVOKABLE void clear();
    Q_INVOKABLE int indexOfBvid(const QString &bvid) const;
    Q_INVOKABLE int indexOfAid(qint64 aid) const;
    Q_INVOKABLE int indexOfLastWatched() const;
    Q_INVOKABLE int indexOfLastWatchedRank(int rank) const;
    Q_INVOKABLE QString bvidAt(int row) const;
    Q_INVOKABLE void removeAt(int row);
    void appendItems(const QVector<VideoItem> &items);
    void prependItems(const QVector<VideoItem> &items);
    void setLoading(bool loading);
    void setHasMore(bool hasMore);
    void setErrorMessage(const QString &msg);

    static QString formatDuration(int seconds);
    static QString formatCount(qint64 count);
    static VideoItem parseVideoItem(const QJsonObject &obj);

signals:
    void countChanged();
    void loadingChanged();
    void hasMoreChanged();
    void errorMessageChanged();

private:
    QVector<VideoItem> m_items;
    bool m_loading;
    bool m_hasMore;
    QString m_errorMessage;
};

// ============ 评论列表模型 ============

class CommentListModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY totalCountChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorMessageChanged)

public:
    enum Roles {
        RpidRole = Qt::UserRole + 1,
        UserNameRole,
        UserMidRole,
        AvatarRole,
        LevelRole,
        ContentRole,
        EmotesRole,
        PicturesRole,
        LikesRole,
        RcountRole,
        CtimeRole,
        CtimeTextRole,
        IsVipRole,
        IsTopRole,
        LikedRole
    };
    Q_ENUM(Roles)

    explicit CommentListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    bool loading() const;
    int totalCount() const;
    QString errorMessage() const;

    Q_INVOKABLE void clear();
    void appendItems(const QVector<CommentItem> &items);
    void setLoading(bool loading);
    void setTotalCount(int total);
    void setErrorMessage(const QString &msg);
    bool setLikeState(qint64 rpid, bool liked);

    static CommentItem parseCommentItem(const QJsonObject &obj);
    static QString formatTime(qint64 timestamp);

signals:
    void countChanged();
    void loadingChanged();
    void totalCountChanged();
    void errorMessageChanged();

private:
    QVector<CommentItem> m_items;
    bool m_loading;
    int m_totalCount;
    QString m_errorMessage;
};

// ============ 子评论列表模型 ============

class CommentReplyListModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY totalCountChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorMessageChanged)

public:
    enum Roles {
        RpidRole = Qt::UserRole + 1,
        UserNameRole,
        UserMidRole,
        AvatarRole,
        LevelRole,
        ContentRole,
        EmotesRole,
        PicturesRole,
        LikesRole,
        CtimeRole,
        CtimeTextRole,
        IsVipRole,
        LikedRole
    };
    Q_ENUM(Roles)

    explicit CommentReplyListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    int totalCount() const;
    bool loading() const;
    QString errorMessage() const;

    Q_INVOKABLE void clear();
    void setItems(const QVector<CommentReplyItem> &items);
    void appendItems(const QVector<CommentReplyItem> &items);
    void setLoading(bool loading);
    void setErrorMessage(const QString &msg);
    void setTotalCount(int total);
    bool setLikeState(qint64 rpid, bool liked);

    static CommentReplyItem parseCommentReplyItem(const QJsonObject &obj);

signals:
    void countChanged();
    void totalCountChanged();
    void loadingChanged();
    void errorMessageChanged();

private:
    QVector<CommentReplyItem> m_items;
    int m_totalCount = 0;
    bool m_loading = false;
    QString m_errorMessage;
};

// ============ 热搜模型 ============

class HotSearchModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    enum Roles {
        KeywordRole = Qt::UserRole + 1,
        IconRole,
        PositionRole
    };
    Q_ENUM(Roles)

    explicit HotSearchModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    bool loading() const;

    Q_INVOKABLE void clear();
    void setItems(const QVector<HotSearchItem> &items);
    void setLoading(bool loading);

signals:
    void countChanged();
    void loadingChanged();

private:
    QVector<HotSearchItem> m_items;
    bool m_loading;
};

// ============ 动态列表模型 ============

class DynamicListModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY hasMoreChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorMessageChanged)

public:
    enum Roles {
        IdStrRole = Qt::UserRole + 1,
        TypeRole,
        VisibleRole,
        AuthorNameRole,
        AuthorFaceRole,
        AuthorMidRole,
        PubActionRole,
        PubTimeRole,
        PubTsRole,
        TextRole,
        IsForwardRole,
        OrigSummaryRole,
        OrigTitleRole,
        OrigCoverRole,
        OrigBvidRole,
        OrigAidRole,
        MajorTypeRole,
        MajorTitleRole,
        MajorCoverRole,
        MajorBvidRole,
        MajorAidRole,
        MajorDurationTextRole,
        PicturesRole,
        RepostCountRole,
        CommentCountRole,
        LikeCountRole,
        RepostCountTextRole,
        CommentCountTextRole,
        LikeCountTextRole,
        CommentOidRole,
        CommentTypeRole,
        IsVideoRole,
        IsImageRole,
        IsArticleRole,
        IsLiveRole
    };
    Q_ENUM(Roles)

    explicit DynamicListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    bool loading() const;
    bool hasMore() const;
    QString errorMessage() const;

    Q_INVOKABLE void clear();
    void appendItems(const QVector<DynamicItem> &items);
    void setLoading(bool loading);
    void setHasMore(bool hasMore);
    void setErrorMessage(const QString &msg);

    static DynamicItem parseDynamicItem(const QJsonObject &obj);

signals:
    void countChanged();
    void loadingChanged();
    void hasMoreChanged();
    void errorMessageChanged();

private:
    QVector<DynamicItem> m_items;
    bool m_loading = false;
    bool m_hasMore = true;
    QString m_errorMessage;
};

// ============ 搜索结果模型（复用 VideoListModel 结构）============

class SearchResultModel : public VideoListModel
{
    Q_OBJECT
    Q_PROPERTY(QString keyword READ keyword NOTIFY keywordChanged)

public:
    explicit SearchResultModel(QObject *parent = nullptr);

    QString keyword() const;
    void setKeyword(const QString &keyword);

    Q_INVOKABLE void clear();

signals:
    void keywordChanged();

private:
    QString m_keyword;
};

// ============ 视频分P列表模型 ============

class VideoPartListModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Roles {
        CidRole = Qt::UserRole + 1,
        PageRole,
        PartRole,
        DurationRole,
        DurationTextRole
    };
    Q_ENUM(Roles)

    explicit VideoPartListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    QVector<VideoPartItem> items() const;

    Q_INVOKABLE void clear();
    void setItems(const QVector<VideoPartItem> &items);

    static VideoPartItem parseVideoPartItem(const QJsonObject &obj);

signals:
    void countChanged();

private:
    QVector<VideoPartItem> m_items;
};

// ============ 收藏夹列表模型 ============

class FavoriteFolderModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        FidRole,
        TitleRole,
        CoverRole,
        MediaCountRole,
        IntroRole,
        AttrRole
    };
    Q_ENUM(Roles)

    explicit FavoriteFolderModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const;
    bool loading() const;

    Q_INVOKABLE void clear();
    void setItems(const QVector<FavoriteFolderItem> &items);
    void setLoading(bool loading);
    void updateCover(qint64 id, const QString &cover);

    static FavoriteFolderItem parseFavoriteFolderItem(const QJsonObject &obj);

signals:
    void countChanged();
    void loadingChanged();

private:
    QVector<FavoriteFolderItem> m_items;
    bool m_loading = false;
};

// ============ UP 主合集/系列模型 ============

class UpSeasonListModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    enum Roles {
        SeasonIdRole = Qt::UserRole + 1,
        NameRole,
        CoverRole,
        TotalRole,
        IsSeriesRole
    };
    Q_ENUM(Roles)

    explicit UpSeasonListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return m_items.count(); }
    bool loading() const { return m_loading; }

    Q_INVOKABLE void clear();
    void setItems(const QVector<UpSeasonItem> &items);
    void setLoading(bool loading);

signals:
    void countChanged();
    void loadingChanged();

private:
    QVector<UpSeasonItem> m_items;
    bool m_loading = false;
};
