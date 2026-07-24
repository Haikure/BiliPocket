#pragma once

#include <QObject>
#include <QtGlobal>

class BiliController;

class BiliLoginModule : public QObject {
  Q_OBJECT
public:
  explicit BiliLoginModule(BiliController *controller);

  Q_INVOKABLE void generateQrcode();
  Q_INVOKABLE void pollQrcode();
  Q_INVOKABLE void startSmsLogin();
  Q_INVOKABLE void stopSmsLogin();
  Q_INVOKABLE void pollSmsLogin();
  Q_INVOKABLE bool smsLoginRunning() const;
  Q_INVOKABLE QString smsLoginLastError() const;
  Q_INVOKABLE void checkLoginStatus();
  Q_INVOKABLE void refreshUserInfo();
  Q_INVOKABLE void refreshUserInfoIfStale();
  void refreshLoginInfo();
  void fetchUserInfo(qint64 mid);
  Q_INVOKABLE void logout();

private:
  BiliController *m_controller;
};
