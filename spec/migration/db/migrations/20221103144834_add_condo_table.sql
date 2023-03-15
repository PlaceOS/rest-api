-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied

CREATE TABLE "condo_uploads" (
    id bigint PRIMARY KEY,
    user_id character varying,
    file_name character varying,
    file_size integer,
    file_id character varying,
    provider_namespace character varying,
    provider_name character varying,
    provider_location character varying,
    bucket_name character varying,
    object_key character varying,
    object_options text,
    resumable_id character varying,
    resumable boolean DEFAULT false,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    file_path text,
    part_list character varying,
    part_data text
);

CREATE SEQUENCE public.condo_uploads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.condo_uploads_id_seq OWNED BY "condo_uploads".id;
ALTER TABLE ONLY "condo_uploads" ALTER COLUMN id SET DEFAULT nextval('public.condo_uploads_id_seq'::regclass);


-- +micrate Down
-- SQL section 'Down' is executed when this migration is rolled back

DROP TABLE IF EXISTS "condo_uploads"