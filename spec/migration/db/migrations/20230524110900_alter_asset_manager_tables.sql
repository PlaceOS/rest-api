-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied

-- Drop Constraints
ALTER TABLE "asset" DROP CONSTRAINT IF EXISTS asset_asset_type_id_fkey;
ALTER TABLE "asset" DROP CONSTRAINT IF EXISTS asset_purchase_order_id_fkey;
ALTER TABLE "asset_type" DROP CONSTRAINT IF EXISTS asset_type_category_id_fkey;
ALTER TABLE "asset_category" DROP CONSTRAINT IF EXISTS asset_category_parent_category_id_fkey;

-- Change Column Type with Data Conversion
ALTER TABLE "asset_category" ALTER COLUMN id TYPE text USING id::text;
ALTER TABLE "asset_category" ALTER COLUMN parent_category_id TYPE text USING parent_category_id::text;
ALTER TABLE "asset_type" ALTER COLUMN id TYPE text USING id::text;
ALTER TABLE "asset_type" ALTER COLUMN category_id TYPE text USING category_id::text;
ALTER TABLE "asset_purchase_order" ALTER COLUMN id TYPE text USING id::text;
ALTER TABLE "asset" ALTER COLUMN id TYPE text USING id::text;
ALTER TABLE "asset" ALTER COLUMN asset_type_id TYPE text USING asset_type_id::text;
ALTER TABLE "asset" ALTER COLUMN purchase_order_id TYPE text USING purchase_order_id::text;

-- Re-add Constraints
ALTER TABLE "asset_category"
    ADD CONSTRAINT asset_category_parent_category_id_fkey FOREIGN KEY (parent_category_id) REFERENCES "asset_category"(id) ON DELETE CASCADE;
ALTER TABLE "asset_type"
    ADD CONSTRAINT asset_type_category_id_fkey FOREIGN KEY (category_id) REFERENCES "asset_category"(id) ON DELETE CASCADE;
ALTER TABLE "asset"
    ADD CONSTRAINT asset_asset_type_id_fkey FOREIGN KEY (asset_type_id) REFERENCES "asset_type"(id) ON DELETE CASCADE; 
ALTER TABLE "asset"
    ADD CONSTRAINT asset_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES "asset_purchase_order"(id) ON DELETE CASCADE; 

-- Remove Default
ALTER TABLE "asset_category" ALTER COLUMN id DROP DEFAULT;
ALTER TABLE "asset_type" ALTER COLUMN id DROP DEFAULT;
ALTER TABLE "asset_purchase_order" ALTER COLUMN id DROP DEFAULT;
ALTER TABLE "asset" ALTER COLUMN id DROP DEFAULT;

-- Drop Sequences
DROP SEQUENCE IF EXISTS asset_category_id_seq;
DROP SEQUENCE IF EXISTS asset_type_id_seq;
DROP SEQUENCE IF EXISTS asset_purchase_order_id_seq;
DROP SEQUENCE IF EXISTS asset_id_seq;

-- +micrate Down
-- SQL section 'Down' is executed when this migration is rolled back

-- Drop Constraints
ALTER TABLE "asset" DROP CONSTRAINT IF EXISTS asset_asset_type_id_fkey;
ALTER TABLE "asset" DROP CONSTRAINT IF EXISTS asset_purchase_order_id_fkey;
ALTER TABLE "asset_type" DROP CONSTRAINT IF EXISTS asset_type_category_id_fkey;
ALTER TABLE "asset_category" DROP CONSTRAINT IF EXISTS asset_category_parent_category_id_fkey;

-- Change Column Type with Data Conversion
ALTER TABLE "asset_category" ALTER COLUMN id TYPE bigint USING id::bigint;
ALTER TABLE "asset_category" ALTER COLUMN parent_category_id TYPE bigint USING parent_category_id::bigint;
ALTER TABLE "asset_type" ALTER COLUMN id TYPE bigint USING id::bigint;
ALTER TABLE "asset_type" ALTER COLUMN category_id TYPE bigint USING category_id::bigint;
ALTER TABLE "asset_purchase_order" ALTER COLUMN id TYPE bigint USING id::bigint;
ALTER TABLE "asset" ALTER COLUMN id TYPE bigint USING id::bigint;
ALTER TABLE "asset" ALTER COLUMN asset_type_id TYPE bigint USING asset_type_id::bigint;
ALTER TABLE "asset" ALTER COLUMN purchase_order_id TYPE bigint USING purchase_order_id::bigint;

-- Recreate sequences and set as DEFAULT
CREATE SEQUENCE asset_category_id_seq OWNED BY asset_category.id;
ALTER TABLE asset_category ALTER COLUMN id SET DEFAULT nextval('asset_category_id_seq');

CREATE SEQUENCE asset_type_id_seq OWNED BY asset_type.id;
ALTER TABLE asset_type ALTER COLUMN id SET DEFAULT nextval('asset_type_id_seq');

CREATE SEQUENCE asset_purchase_order_id_seq OWNED BY asset_purchase_order.id;
ALTER TABLE asset_purchase_order ALTER COLUMN id SET DEFAULT nextval('asset_purchase_order_id_seq');

CREATE SEQUENCE asset_id_seq OWNED BY asset.id;
ALTER TABLE asset ALTER COLUMN id SET DEFAULT nextval('asset_id_seq');

-- Re-add Constraints
ALTER TABLE "asset_category"
    ADD CONSTRAINT asset_category_parent_category_id_fkey FOREIGN KEY (parent_category_id) REFERENCES "asset_category"(id) ON DELETE CASCADE;
ALTER TABLE "asset_type"
    ADD CONSTRAINT asset_type_category_id_fkey FOREIGN KEY (category_id) REFERENCES "asset_category"(id) ON DELETE CASCADE;
ALTER TABLE "asset"
    ADD CONSTRAINT asset_asset_type_id_fkey FOREIGN KEY (asset_type_id) REFERENCES "asset_type"(id) ON DELETE CASCADE; 
ALTER TABLE "asset"
    ADD CONSTRAINT asset_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES "asset_purchase_order"(id) ON DELETE CASCADE; 
