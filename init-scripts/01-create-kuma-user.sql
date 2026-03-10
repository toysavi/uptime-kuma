# Uptime Kuma Monitor 
CREATE USER 'kuma_monitor'@'%' IDENTIFIED BY 'M0nitorPassword';
GRANT SELECT ON *.* TO 'kuma_monitor'@'%';
FLUSH PRIVILEGES;
