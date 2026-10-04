CREATE TABLE team_folders (
 team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
 id TEXT NOT NULL, parent_id TEXT, name TEXT NOT NULL,
 revision INTEGER NOT NULL DEFAULT 0, content TEXT NOT NULL DEFAULT '',
 updated_at INTEGER NOT NULL, PRIMARY KEY(team_id,id),
 FOREIGN KEY(team_id,parent_id) REFERENCES team_folders(team_id,id)
);
CREATE UNIQUE INDEX team_folder_sibling_names ON team_folders(team_id,COALESCE(parent_id,''),name);
CREATE TABLE team_folder_grants (
 team_id TEXT NOT NULL, folder_id TEXT NOT NULL, account_id TEXT NOT NULL,
 access TEXT NOT NULL CHECK(access IN ('read','write')),
 PRIMARY KEY(team_id,folder_id,account_id),
 FOREIGN KEY(team_id,folder_id) REFERENCES team_folders(team_id,id) ON DELETE CASCADE,
 FOREIGN KEY(team_id,account_id) REFERENCES team_members(team_id,account_id) ON DELETE CASCADE
);
INSERT INTO team_folders(team_id,id,parent_id,name,revision,content,updated_at)
 SELECT team_id,'root',NULL,'Home',revision,content,updated_at FROM team_documents;
INSERT INTO team_folder_grants(team_id,folder_id,account_id,access)
 SELECT team_id,'root',account_id,'write' FROM team_members;
ALTER TABLE team_invites ADD COLUMN folder_id TEXT NOT NULL DEFAULT 'root';
ALTER TABLE team_invites ADD COLUMN folder_access TEXT NOT NULL DEFAULT 'write' CHECK(folder_access IN ('read','write'));
