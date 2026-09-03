CREATE SCHEMA IF NOT EXISTS demo;

CREATE TABLE IF NOT EXISTS demo.customers (
    id         serial PRIMARY KEY,
    name       text NOT NULL,
    email      text NOT NULL UNIQUE,
    tier       text NOT NULL DEFAULT 'standard',
    created_at timestamptz NOT NULL DEFAULT now()
);
