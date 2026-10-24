-- clawd-wakes-up: PostgreSQL extensions
-- Required: pgvector for semantic search, uuid-ossp for IDs

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
