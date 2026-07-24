#pragma once

#include <QObject>
#include <QtGlobal>
#include <QString>
#include <QStringList>

class BiliController;

class BiliSearchModule : public QObject {
  Q_OBJECT
public:
  explicit BiliSearchModule(BiliController *controller);
  Q_INVOKABLE void search(const QString &keyword, int page = 1);
  Q_INVOKABLE void searchMore();
  Q_INVOKABLE void fetchHotSearch();
  Q_INVOKABLE void clearSearchHistory();
  Q_INVOKABLE void removeSearchHistory(const QString &keyword);
  Q_INVOKABLE QObject *searchModel();
  Q_INVOKABLE QObject *searchHistoryModel();
  Q_INVOKABLE QObject *hotSearchModel();
  void loadSearchHistory();

private:
  void saveSearchHistory();

  BiliController *m_controller;
  int m_searchPage = 1;
  QString m_searchKeyword;
  QStringList m_searchHistory;
};
