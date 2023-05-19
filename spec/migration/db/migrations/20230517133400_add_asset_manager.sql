-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied

-- Remove old tables/indexes
DROP INDEX IF EXISTS "ass_requester_id_index";
DROP INDEX IF EXISTS "ass_zone_id_index";
DROP INDEX IF EXISTS "ass_asset_id_index";
DROP TABLE IF EXISTS "ass";
DROP INDEX IF EXISTS "asset_parent_id_index";
DROP TABLE IF EXISTS "asset";

-- New asset manager tables/indexes
CREATE TABLE IF NOT EXISTS "asset_category" (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    description text,
    parent_category_id bigint,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL  
);

CREATE INDEX IF NOT EXISTS asset_category_parent_id_index ON "asset_category" USING BTREE (parent_category_id);

ALTER TABLE ONLY "asset_category"
    DROP CONSTRAINT IF EXISTS asset_category_parent_category_id_fkey;

ALTER TABLE ONLY "asset_category"
    ADD CONSTRAINT asset_category_parent_category_id_fkey FOREIGN KEY (parent_category_id) REFERENCES "asset_category"(id) ON DELETE CASCADE; 

CREATE TABLE IF NOT EXISTS "asset_type" (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    brand text,
    description text,
    model_number text,
    images text[],
    category_id bigint NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL 
);

CREATE INDEX IF NOT EXISTS asset_type_category_id_index ON "asset_type" USING BTREE (category_id);

ALTER TABLE ONLY "asset_type"
    DROP CONSTRAINT IF EXISTS asset_type_category_id_fkey;

ALTER TABLE ONLY "asset_type"
    ADD CONSTRAINT asset_type_category_id_fkey FOREIGN KEY (category_id) REFERENCES "asset_category"(id) ON DELETE CASCADE; 

CREATE TABLE IF NOT EXISTS "asset_purchase_order" (
    id bigserial PRIMARY KEY,
    purchase_order_number text NOT NULL,
    invoice_number text,
    supplier_details jsonb DEFAULT '{}'::jsonb,
    purchase_date bigint,
    unit_price bigint,
    expected_service_start_date bigint,
    expected_service_end_date bigint,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS "asset" (
    id bigserial PRIMARY KEY,
    identifier text,
    serial_number text,
    other_data jsonb DEFAULT '{}'::jsonb,
    asset_type_id bigint NOT NULL,
    purchase_order_id bigint,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL 
);

CREATE INDEX IF NOT EXISTS asset_asset_type_id_index ON "asset" USING BTREE (asset_type_id);
CREATE INDEX IF NOT EXISTS asset_purchase_order_id_index ON "asset" USING BTREE (purchase_order_id);

ALTER TABLE ONLY "asset"
    ADD CONSTRAINT asset_asset_type_id_fkey FOREIGN KEY (asset_type_id) REFERENCES "asset_type"(id) ON DELETE CASCADE; 

ALTER TABLE ONLY "asset"
    ADD CONSTRAINT asset_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES "asset_purchase_order"(id) ON DELETE CASCADE; 

-- +micrate Down
-- SQL section 'Down' is executed when this migration is rolled back

-- Table for model PlaceOS::Model::Asset
CREATE TABLE IF NOT EXISTS "asset"(
     created_at TIMESTAMPTZ NOT NULL,
   updated_at TIMESTAMPTZ NOT NULL,
   name TEXT NOT NULL,
   category TEXT NOT NULL,
   description TEXT NOT NULL,
   purchase_date TIMESTAMPTZ NOT NULL,
   good_until_date TIMESTAMPTZ,
   identifier TEXT,
   brand TEXT NOT NULL,
   purchase_price INTEGER NOT NULL,
   images TEXT[] NOT NULL,
   invoice TEXT,
   quantity INTEGER NOT NULL,
   in_use INTEGER NOT NULL,
   other_data JSONB NOT NULL,
   parent_id TEXT,
   id TEXT NOT NULL PRIMARY KEY
);

CREATE INDEX IF NOT EXISTS asset_parent_id_index ON "asset" USING BTREE (parent_id);

-- Table for model PlaceOS::Model::AssetInstance
CREATE TABLE IF NOT EXISTS "ass"(
     created_at TIMESTAMPTZ NOT NULL,
   updated_at TIMESTAMPTZ NOT NULL,
   name TEXT NOT NULL,
   tracking INTEGER NOT NULL,
   approval BOOLEAN NOT NULL,
   asset_id TEXT,
   requester_id TEXT,
   zone_id TEXT,
   usage_start TIMESTAMPTZ NOT NULL,
   usage_end TIMESTAMPTZ NOT NULL,
   id TEXT NOT NULL PRIMARY KEY
);

CREATE INDEX IF NOT EXISTS ass_asset_id_index ON "ass" USING BTREE (asset_id);
CREATE INDEX IF NOT EXISTS ass_zone_id_index ON "ass" USING BTREE (zone_id);
CREATE INDEX IF NOT EXISTS ass_requester_id_index ON "ass" USING BTREE (requester_id);
