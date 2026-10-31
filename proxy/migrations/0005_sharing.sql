-- Who spreads the app: each install's share code (the one in the links it shares, see AppGroup.shareCode),
-- and how often each code's links are opened on the website, a day at a time (see site/src/worker.ts):
-- the code, the day, and whether it was a QR code; nothing about who opened it.
ALTER TABLE presence ADD COLUMN share_code TEXT NOT NULL DEFAULT '';
CREATE INDEX presence_share_code ON presence (share_code);
CREATE TABLE link_opens (
  code  TEXT    NOT NULL,
  day   TEXT    NOT NULL,           -- YYYY-MM-DD, UTC
  qr    INTEGER NOT NULL DEFAULT 0, -- 1: scanned from a QR code
  opens INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (code, day, qr)
);
