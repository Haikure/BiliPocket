#pragma once

#include <QObject>
#include <QString>
#include <QtGlobal>

class BiliController;

class BiliFeedModule : public QObject {
  Q_OBJECT
public:
  explicit BiliFeedModule(BiliController *controller);
  Q_INVOKABLE void fetchPopular(int page = 1, int pageSize = 10);
  Q_INVOKABLE void fetchMorePopular();
  Q_INVOKABLE void fetchRanking(int rid = 0);
  Q_INVOKABLE void fetchDynamic(const QString &type = QString(), const QString &offset = QString(), qint64 hostMid = 0);
  Q_INVOKABLE void fetchMoreDynamic();
  Q_INVOKABLE void fetchUpDynamics(qint64 hostMid, const QString &offset = QString());
  Q_INVOKABLE void fetchMoreUpDynamics();
  Q_INVOKABLE void fetchHotSearch();
  Q_INVOKABLE QObject *popularModel();
  Q_INVOKABLE QObject *rankingModel();
  Q_INVOKABLE QObject *dynamicModel();
  Q_INVOKABLE QObject *upDynamicModel();
  Q_INVOKABLE QObject *hotSearchModel();

private:
  BiliController *m_controller;
  int m_popularPage = 1;
  QString m_dynamicType = QStringLiteral("all");
  QString m_dynamicOffset;
  qint64 m_dynamicHostMid = 0;
  QString m_upDynamicOffset;
  qint64 m_upDynamicHostMid = 0;
};
