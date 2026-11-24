CREATE TABLE "library_members" (
	"library_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"role" text DEFAULT 'editor' NOT NULL,
	"invited_by" uuid,
	"joined_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "library_members_library_id_user_id_pk" PRIMARY KEY("library_id","user_id"),
	CONSTRAINT "library_members_role_check" CHECK ("library_members"."role" in ('owner','editor','viewer'))
);
--> statement-breakpoint
CREATE TABLE "library_pending_invites" (
	"library_id" uuid NOT NULL,
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"email" text NOT NULL,
	"role" text DEFAULT 'editor' NOT NULL,
	"invited_by" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"accepted_at" timestamp with time zone,
	CONSTRAINT "library_pending_invites_role_check" CHECK ("library_pending_invites"."role" in ('editor','viewer')),
	CONSTRAINT "library_pending_invites_email_check" CHECK ("library_pending_invites"."email" = lower("library_pending_invites"."email"))
);
--> statement-breakpoint
CREATE TABLE "trip_members" (
	"trip_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"role" text DEFAULT 'editor' NOT NULL,
	"invited_by" uuid,
	"joined_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "trip_members_trip_id_user_id_pk" PRIMARY KEY("trip_id","user_id"),
	CONSTRAINT "trip_members_role_check" CHECK ("trip_members"."role" in ('owner','editor','viewer'))
);
--> statement-breakpoint
CREATE TABLE "trip_pending_invites" (
	"trip_id" uuid NOT NULL,
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"email" text NOT NULL,
	"role" text DEFAULT 'editor' NOT NULL,
	"invited_by" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"accepted_at" timestamp with time zone,
	CONSTRAINT "trip_pending_invites_role_check" CHECK ("trip_pending_invites"."role" in ('editor','viewer')),
	CONSTRAINT "trip_pending_invites_email_check" CHECK ("trip_pending_invites"."email" = lower("trip_pending_invites"."email"))
);
--> statement-breakpoint
ALTER TABLE "library_members" ADD CONSTRAINT "library_members_library_id_profiles_id_fk" FOREIGN KEY ("library_id") REFERENCES "public"."profiles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_members" ADD CONSTRAINT "library_members_user_id_profiles_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_members" ADD CONSTRAINT "library_members_invited_by_profiles_id_fk" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_pending_invites" ADD CONSTRAINT "library_pending_invites_library_id_profiles_id_fk" FOREIGN KEY ("library_id") REFERENCES "public"."profiles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_pending_invites" ADD CONSTRAINT "library_pending_invites_invited_by_profiles_id_fk" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trip_members" ADD CONSTRAINT "trip_members_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trip_members" ADD CONSTRAINT "trip_members_user_id_profiles_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trip_members" ADD CONSTRAINT "trip_members_invited_by_profiles_id_fk" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trip_pending_invites" ADD CONSTRAINT "trip_pending_invites_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trip_pending_invites" ADD CONSTRAINT "trip_pending_invites_invited_by_profiles_id_fk" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "library_members_user_idx" ON "library_members" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "library_pending_invites_library_email_idx" ON "library_pending_invites" USING btree ("library_id","email");--> statement-breakpoint
CREATE INDEX "library_pending_invites_email_idx" ON "library_pending_invites" USING btree ("email");--> statement-breakpoint
CREATE INDEX "trip_members_user_idx" ON "trip_members" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "trip_pending_invites_trip_email_idx" ON "trip_pending_invites" USING btree ("trip_id","email");--> statement-breakpoint
CREATE INDEX "trip_pending_invites_email_idx" ON "trip_pending_invites" USING btree ("email");