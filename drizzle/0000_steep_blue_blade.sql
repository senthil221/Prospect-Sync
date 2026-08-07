CREATE TABLE `clients` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`normalized_name` text NOT NULL,
	`created_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `idx_clients_normalized_name` ON `clients` (`normalized_name`);--> statement-breakpoint
CREATE TABLE `companies` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text DEFAULT '' NOT NULL,
	`normalized_name` text DEFAULT '' NOT NULL,
	`domain` text DEFAULT '' NOT NULL,
	`normalized_domain` text DEFAULT '' NOT NULL,
	`all_data` text DEFAULT '{}' NOT NULL,
	`created_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	`updated_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_companies_normalized_name` ON `companies` (`normalized_name`);--> statement-breakpoint
CREATE INDEX `idx_companies_normalized_domain` ON `companies` (`normalized_domain`);--> statement-breakpoint
CREATE TABLE `imports` (
	`id` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`list_id` text NOT NULL,
	`file_name` text NOT NULL,
	`status` text DEFAULT 'processing' NOT NULL,
	`total_rows` integer DEFAULT 0 NOT NULL,
	`processed_rows` integer DEFAULT 0 NOT NULL,
	`unique_added` integer DEFAULT 0 NOT NULL,
	`duplicates_linked` integer DEFAULT 0 NOT NULL,
	`created_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	`completed_at` text,
	FOREIGN KEY (`client_id`) REFERENCES `clients`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`list_id`) REFERENCES `lists`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `idx_imports_created_at` ON `imports` (`created_at`);--> statement-breakpoint
CREATE TABLE `list_memberships` (
	`list_id` text NOT NULL,
	`prospect_id` text NOT NULL,
	`import_id` text NOT NULL,
	`raw_data` text DEFAULT '{}' NOT NULL,
	`imported_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	PRIMARY KEY(`list_id`, `prospect_id`),
	FOREIGN KEY (`list_id`) REFERENCES `lists`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`prospect_id`) REFERENCES `prospects`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`import_id`) REFERENCES `imports`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `idx_list_memberships_prospect_id` ON `list_memberships` (`prospect_id`);--> statement-breakpoint
CREATE TABLE `lists` (
	`id` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`name` text NOT NULL,
	`source_file_name` text DEFAULT '' NOT NULL,
	`uploaded_rows` integer DEFAULT 0 NOT NULL,
	`unique_added` integer DEFAULT 0 NOT NULL,
	`duplicates_linked` integer DEFAULT 0 NOT NULL,
	`created_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	FOREIGN KEY (`client_id`) REFERENCES `clients`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `idx_lists_client_id` ON `lists` (`client_id`);--> statement-breakpoint
CREATE TABLE `prospect_identifiers` (
	`type` text NOT NULL,
	`value` text NOT NULL,
	`prospect_id` text NOT NULL,
	`created_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	PRIMARY KEY(`type`, `value`),
	FOREIGN KEY (`prospect_id`) REFERENCES `prospects`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `idx_prospect_identifiers_prospect_id` ON `prospect_identifiers` (`prospect_id`);--> statement-breakpoint
CREATE TABLE `prospects` (
	`id` text PRIMARY KEY NOT NULL,
	`first_name` text DEFAULT '' NOT NULL,
	`last_name` text DEFAULT '' NOT NULL,
	`full_name` text DEFAULT '' NOT NULL,
	`work_email` text DEFAULT '' NOT NULL,
	`personal_email` text DEFAULT '' NOT NULL,
	`mobile_number` text DEFAULT '' NOT NULL,
	`linkedin_url` text DEFAULT '' NOT NULL,
	`title` text DEFAULT '' NOT NULL,
	`seniority` text DEFAULT '' NOT NULL,
	`department` text DEFAULT '' NOT NULL,
	`city` text DEFAULT '' NOT NULL,
	`state` text DEFAULT '' NOT NULL,
	`country` text DEFAULT '' NOT NULL,
	`company_id` text,
	`all_data` text DEFAULT '{}' NOT NULL,
	`created_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	`updated_at` text DEFAULT CURRENT_TIMESTAMP NOT NULL,
	FOREIGN KEY (`company_id`) REFERENCES `companies`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `idx_prospects_company_id` ON `prospects` (`company_id`);--> statement-breakpoint
CREATE INDEX `idx_prospects_full_name` ON `prospects` (`full_name`);