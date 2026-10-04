/* The connection remains account-owned; this selects billing entitlement only. */
ALTER TABLE mcp_connections ADD COLUMN team_id TEXT;
CREATE INDEX mcp_connections_license_team ON mcp_connections(team_id);
