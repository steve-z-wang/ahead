CREATE TABLE IF NOT EXISTS otter_client (
 client_id text PRIMARY KEY,
 owner_id text NOT NULL,
 sequence bigint NOT NULL DEFAULT 0 CHECK(sequence >= 0 AND sequence <= 9007199254740991),
 receipt text
);
CREATE TABLE IF NOT EXISTS otter_channel (
 channel text PRIMARY KEY,
 head bigint NOT NULL CHECK(head >= 0 AND head <= 9007199254740991)
);
CREATE TABLE IF NOT EXISTS otter_invalidation (
 channel text NOT NULL REFERENCES otter_channel(channel),
 model text NOT NULL,
 identity_key text NOT NULL,
 identity jsonb NOT NULL,
 cursor bigint NOT NULL CHECK(cursor > 0 AND cursor <= 9007199254740991),
 PRIMARY KEY(channel,model,identity_key),
 UNIQUE(channel,cursor)
);
