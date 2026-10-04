CREATE TABLE personal_libraries (
 account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
 tree_revision INTEGER NOT NULL DEFAULT 0,
 tree_json TEXT NOT NULL DEFAULT '[{"id":"root","parent_id":null,"name":"Home"}]'
);
CREATE TABLE personal_folders (
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 id TEXT NOT NULL,
 parent_id TEXT,
 name TEXT NOT NULL,
 revision INTEGER NOT NULL DEFAULT 0,
 content TEXT NOT NULL DEFAULT '',
 updated_at INTEGER NOT NULL DEFAULT 0,
 deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),
 PRIMARY KEY(account_id,id)
);
INSERT INTO personal_libraries(account_id) SELECT id FROM accounts;
INSERT INTO personal_folders(account_id,id,parent_id,name) SELECT id,'root',NULL,'Home' FROM accounts;
CREATE TRIGGER personal_tree_update AFTER UPDATE OF tree_json ON personal_libraries BEGIN
 UPDATE personal_folders SET deleted=1 WHERE account_id=NEW.account_id AND id<>'root';
 INSERT INTO personal_folders(account_id,id,parent_id,name,deleted)
 SELECT NEW.account_id,json_extract(value,'$.id'),json_extract(value,'$.parent_id'),json_extract(value,'$.name'),0 FROM json_each(NEW.tree_json) WHERE 1
 ON CONFLICT(account_id,id) DO UPDATE SET parent_id=excluded.parent_id,name=excluded.name,deleted=0;
END;
CREATE TRIGGER personal_library_create AFTER INSERT ON accounts BEGIN
 INSERT INTO personal_libraries(account_id) VALUES(NEW.id);
 INSERT INTO personal_folders(account_id,id,parent_id,name) VALUES(NEW.id,'root',NULL,'Home');
END;
