CREATE TABLE IF NOT EXISTS `user_vehicle_insurance` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `discordid` varchar(50) NOT NULL,
  `plate` varchar(32) NOT NULL,
  `policy_type` varchar(32) NOT NULL DEFAULT 'standard',
  `premium` int(11) NOT NULL DEFAULT 250,
  `deductible` int(11) NOT NULL DEFAULT 1000,
  `vehicle_props` longtext DEFAULT NULL,
  `next_payment_at` int(11) NOT NULL DEFAULT 0,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_policy` (`discordid`,`plate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
