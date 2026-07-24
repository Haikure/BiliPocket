#pragma once

#include <QObject>
#include <QtGlobal>

class BiliController;

class BiliFavoriteModule : public QObject {
  Q_OBJECT
public:
  explicit BiliFavoriteModule(BiliController *controller);
  Q_INVOKABLE void fetchFavoriteFolders();
  Q_INVOKABLE void fetchFavoriteItems(qint64 mediaId, int page = 1, int pageSize = 20);
  Q_INVOKABLE void fetchMoreFavoriteItems();
  Q_INVOKABLE void fetchFavoriteStatus();
  Q_INVOKABLE void fetchCoinStatus();
  Q_INVOKABLE void addCoin(int multiply = 1, bool selectLike = false);
  Q_INVOKABLE void fetchLikeStatus();
  Q_INVOKABLE void fetchWatchLaterStatus();
  Q_INVOKABLE void toggleLike();
  Q_INVOKABLE void toggleFavorite();
  Q_INVOKABLE void toggleFavoriteTo(qint64 mediaId);
  Q_INVOKABLE void toggleWatchLater();
  Q_INVOKABLE QObject *favoriteFolderModel();
  Q_INVOKABLE QObject *favoriteItemModel();
  void resetLoadingState();

private:
  BiliController *m_controller;
  int m_favoritePage = 1;
  qint64 m_currentFavoriteId = 0;
  qint64 m_favoriteStatusLoadingAid = 0;
  qint64 m_coinStatusLoadingAid = 0;
  qint64 m_likeStatusLoadingAid = 0;
  qint64 m_watchLaterStatusLoadingAid = 0;
};
