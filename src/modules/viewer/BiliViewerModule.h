#pragma once

#include <QObject>
#include <QtGlobal>
#include <QString>

class BiliController;

class BiliViewerModule : public QObject {
  Q_OBJECT
public:
  explicit BiliViewerModule(BiliController *controller);
  Q_INVOKABLE void prepareImageForViewer(const QString &url);

private:
  BiliController *m_controller;
};
