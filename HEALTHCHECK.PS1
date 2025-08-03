# Define SQL Servers
$servers = get-content -path "C:\Healthcheck-report\serverlist.txt"

# Define SQL query to collect metrics
$uptimequery = @"
SELECT 
    sqlserver_start_time AS 'SQL Server Start Time',
    DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) / 86400 AS 'Days',
    (DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) % 86400) / 3600 AS 'Hours',
    ((DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) % 86400) % 3600) / 60 AS 'Minutes',
    ((DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) % 86400) % 3600) % 60 AS 'Seconds',
    DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS 'Total Uptime (Seconds)'
FROM sys.dm_os_sys_info;
"@
 
$query = @"
SELECT DISTINCT
    ROW_NUMBER() OVER (ORDER BY SERVERPROPERTY('servername')) AS 'SNO',
    SERVERPROPERTY('servername') AS ServerName,
    (SELECT 'Online') AS Status,
    LEFT (@@VERSION, 37) AS SQL_Version,
    SERVERPROPERTY('ProductVersion') AS SQLVersion,
    SERVERPROPERTY('ProductLevel') AS ProductLevel,
    SERVERPROPERTY('Edition') AS Edition,
    (SELECT COUNT(*) FROM sys.databases WHERE state = 0) AS OnlineDatabases,
    (SELECT SUM((mFiles.size) * 8 / 1024) / 1024 FROM SYS.MASTER_FILES mFiles 
     INNER JOIN SYS.DATABASES dbs ON dbs.DATABASE_ID = mFiles.DATABASE_ID) AS Tot_DB_Size_GB,
    (SELECT COUNT(*) FROM sys.dm_exec_requests) AS ActiveRequests,
    (SELECT cpu_count FROM sys.dm_os_sys_info) AS No_Of_Processors,
    (SELECT FORMAT((physical_memory_kb / 1024.00 / 1024.00), 'N2') FROM sys.dm_os_sys_info) AS TotPhysicalMemory,
    (SELECT c.value FROM sys.configurations c WHERE c.[name] = 'max server memory (MB)') AS SQL_Memory
"@


# Define SQL query to collect backup report with database mode
$backupQuery = @"
SELECT  @@servername as Server_name, 
        name AS DBName ,
        recovery_model_desc AS RecoveryModel ,
        state_desc AS DBStatus ,
        user_access_desc AS DBMode ,
        d AS 'LastFullBackup' ,
        i AS 'LastDiffBackup' ,
        l AS 'LastLogBackup'
FROM    ( SELECT    db.name ,
                    db.state_desc ,
                    db.recovery_model_desc ,
                    db.user_access_desc ,
                    type ,
                    backup_finish_date
          FROM      master.sys.databases db
                    LEFT OUTER JOIN msdb.dbo.backupset a ON a.database_name = db.name
        ) AS Sourcetable 
    PIVOT 
        ( MAX(backup_finish_date) FOR type IN ( D, I, L ) ) AS MostRecentBackup 
WHERE name<>'tempdb' 
ORDER BY Server_name, RecoveryModel, DBMode
"@


#CPU utilization
$cpu = @"
--> STEP 1 : Collect CPU Utilization from sys.dm_os_ring_buffers

SET NOCOUNT ON;
DECLARE @ts_now BIGINT;

-- Get system tick count
SELECT @ts_now = cpu_ticks / (cpu_ticks / ms_ticks) 
FROM sys.dm_os_sys_info;

-- Load last 10 records into temp table
SELECT TOP (10)
    SQLProcessUtilization AS [SQLServerProcessCPUUtilization],
    SystemIdle AS [SystemIdleProcess],
    100 - SystemIdle AS [TotalCPUUtilization],
    100 - SystemIdle - SQLProcessUtilization AS [OtherProcessCPUUtilization],
    DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS [EventTime]
INTO #CPUUtilization
FROM (
    SELECT
        record.value('(./Record/@id)[1]', 'int') AS record_id,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS [SystemIdle],
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS [SQLProcessUtilization],
        [timestamp]
    FROM (
        SELECT [timestamp], CONVERT(XML, record) AS [record]
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
        AND record LIKE '%<SystemHealth>%'
    ) AS x
) AS y
ORDER BY record_id DESC;

--> STEP 2 : Processor Metadata from sys.dm_os_sys_info and xp_msver

DECLARE @xp_msver TABLE (
    [idx] INT,
    [c_name] VARCHAR(100),
    [int_val] FLOAT,
    [c_val] VARCHAR(128)
);

INSERT INTO @xp_msver
EXEC('master..xp_msver');

WITH ProcessorInfo AS (
    SELECT 
        (cpu_count / hyperthread_ratio) AS number_of_physical_cpus,
        CASE
            WHEN hyperthread_ratio = cpu_count THEN cpu_count
            ELSE ((cpu_count - hyperthread_ratio) / (cpu_count / hyperthread_ratio))
        END AS number_of_cores_per_cpu,
        CASE
            WHEN hyperthread_ratio = cpu_count THEN cpu_count
            ELSE (cpu_count / hyperthread_ratio) * ((cpu_count - hyperthread_ratio) / (cpu_count / hyperthread_ratio))
        END AS total_number_of_cores,
        cpu_count AS number_of_virtual_cpus,
        (
            SELECT c_val
            FROM @xp_msver
            WHERE c_name = 'Platform'
        ) AS cpu_category
    FROM sys.dm_os_sys_info
),
ProcessorInfo1 AS (
    SELECT 
        @@SERVERNAME AS servername,
        number_of_physical_cpus,
        number_of_cores_per_cpu,
        total_number_of_cores,
        number_of_virtual_cpus,
        LTRIM(RIGHT(cpu_category, CHARINDEX('x', cpu_category) - 1)) AS cpu_category
    FROM ProcessorInfo
),
CPUUtilizationSummary AS (
    SELECT 
        @@SERVERNAME AS ServerName,
        AVG(SQLServerProcessCPUUtilization) AS SQLServerCPU,
        AVG(TotalCPUUtilization) AS TotalCPUUsage,
        AVG(OtherProcessCPUUtilization) AS OtherProcessCPU,
        CASE
            WHEN AVG(TotalCPUUtilization) >= 90 THEN 'Total CPU Usage is Very High'
            WHEN AVG(TotalCPUUtilization) >= 80 THEN 'Total CPU Usage is High'
            ELSE 'CPU Utilisation looks Good'
        END AS Status
    FROM #CPUUtilization
)

-- Final Select with everything
SELECT 
    A.servername,
    number_of_physical_cpus,
    number_of_cores_per_cpu,
    total_number_of_cores,
    number_of_virtual_cpus,
    cpu_category,
    B.SQLServerCPU,
    B.OtherProcessCPU,
    B.TotalCPUUsage,
    B.Status
FROM ProcessorInfo1 A
LEFT JOIN CPUUtilizationSummary B ON A.servername = B.ServerName;

--> STEP 3 : Cleanup
DROP TABLE #CPUUtilization;
"@


#Disk Information
$diskquery = @"
-- Create a temporary table to store the disk space information
CREATE TABLE #DiskSpaceInfo (
    Server_Name NVARCHAR(128),
    DiskMountPoint NVARCHAR(128),
    TotalSizeGB DECIMAL(18, 2),
    AvailableSizeGB DECIMAL(18, 2),
    PercentageFree DECIMAL(5, 2),
    Status NVARCHAR(20)
);

-- Insert disk space information into the temporary table
INSERT INTO #DiskSpaceInfo
SELECT
    @@SERVERNAME AS Server_Name,
    vs.volume_mount_point AS DiskMountPoint,
    vs.total_bytes / 1073741824.0 AS TotalSizeGB,
    vs.available_bytes / 1073741824.0 AS AvailableSizeGB,
    ROUND((vs.available_bytes * 100.0 / vs.total_bytes), 2) AS PercentageFree,
    CASE 
        WHEN vs.available_bytes * 100.0 / vs.total_bytes < 10 THEN 'Critical'
        WHEN vs.available_bytes * 100.0 / vs.total_bytes < 20 THEN 'Warning'
        ELSE 'Healthy'
    END AS Status
FROM
    sys.master_files AS mf
CROSS APPLY
    sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
GROUP BY
    vs.volume_mount_point,
    vs.total_bytes,
    vs.available_bytes;

-- Select the disk space information
SELECT 
    Server_Name,
    DiskMountPoint,
    TotalSizeGB,
    AvailableSizeGB,
    PercentageFree AS [SpaceFree],
    Status
FROM 
    #DiskSpaceInfo
ORDER BY 
    DiskMountPoint;

-- Drop the temporary table
DROP TABLE #DiskSpaceInfo;
"@






# HA/DR Comprehensive Script
$logship = @"
-- Log Shipping Health Check (Primary + Secondary)
SELECT 
    'Log Shipping Primary' AS HA_Type,
    primary_database AS Database_Name,
    @@SERVERNAME AS Server_Name,
    'Primary Database' AS Role
FROM msdb.dbo.log_shipping_primary_databases

UNION ALL

SELECT 
    'Log Shipping Secondary' AS HA_Type,
    lsd.secondary_database AS Database_Name,
    @@SERVERNAME AS Server_Name,
    'Secondary Database' AS Role
FROM msdb.dbo.log_shipping_secondary ls
JOIN msdb.dbo.log_shipping_secondary_databases lsd
    ON ls.secondary_id = lsd.secondary_id;


"@

#Mirroring

$mirror=@"
SELECT 
    'Database Mirroring' AS HA_Type,
    database_id,
    database_name = CASE WHEN database_id > 4 THEN DB_NAME(database_id) ELSE NULL END,
    mirroring_guid,
    mirroring_state_desc,
    mirroring_role_desc,
    mirroring_partner_name,
    mirroring_partner_instance,
    mirroring_witness_name,
    mirroring_witness_state_desc,
    mirroring_safety_level_desc,
    mirroring_safety_sequence,
    mirroring_role_sequence,
    mirroring_redo_queue_type
FROM sys.database_mirroring
WHERE database_id > 4 -- Exclude system databases
AND mirroring_state_desc IS NOT NULL;
"@


#Always ON

$Always_ON=@"
SELECT 
    'Always On Instance' AS HA_Type,
    'Instance Level' AS Database_Name,
    @@SERVERNAME AS Server_Name,
    SERVERPROPERTY('IsHadrEnabled') AS AlwaysOnEnabled,
    CASE WHEN SERVERPROPERTY('IsHadrEnabled') = 1 
         THEN 'Always On Availability Groups Enabled' 
         ELSE 'Always On Availability Groups Disabled' 
    END AS Status;


IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    SELECT 
        'Always On AG' AS HA_Type,
        ag.name AS AG_Name,
        ar.replica_server_name AS Server_Name,
        db.database_name AS Database_Name,
        ar.availability_mode_desc,
        ar.failover_mode_desc,
        ars.role_desc,
        ars.connected_state_desc,
        ars.synchronization_health_desc,
        drs.synchronization_state_desc,
        drs.is_suspended,
        ar.endpoint_url,
        ar.session_timeout,
        ar.primary_role_allow_connections_desc,
        ar.secondary_role_allow_connections_desc
    FROM sys.availability_groups ag
    INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
    LEFT JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id
    LEFT JOIN sys.availability_databases_cluster db ON drs.database_id = db.database_id
    ORDER BY ag.name, ar.replica_server_name;
END
"@

#Replication

$Repl=@"

SELECT 
    'Replication' AS HA_Type,
    name AS Database_Name,
    @@SERVERNAME AS Server_Name,
    'Publisher' AS Replication_Role,
    'Published Database' AS Status
FROM sys.databases 
WHERE is_published = 1

UNION ALL

SELECT 
    'Replication' AS HA_Type,
    name AS Database_Name,
    @@SERVERNAME AS Server_Name,
    'Subscriber' AS Replication_Role,
    'Subscriber Database' AS Status
FROM sys.databases 
WHERE is_subscribed = 1

UNION ALL

SELECT 
    'Replication' AS HA_Type,
    'distribution' AS Database_Name,
    @@SERVERNAME AS Server_Name,
    'Distributor' AS Replication_Role,
    'Distributor Server' AS Status
FROM sys.databases
WHERE name = 'distribution';
"@


# SQL Server Job informaton
$jobquery = @"
SELECT * 
FROM (
    SELECT 
        @@servername AS Server_Name,
        S.name AS JobName,
        l.name AS JobOwner,
        SS.name AS ScheduleName, 
        CASE WHEN S.enabled = 1 THEN 'Enabled' 
             ELSE 'Disabled' 
        END AS [IsEnabled],                   
        CASE (SS.freq_type)
            WHEN 1 THEN 'Once'
            WHEN 4 THEN 'Daily'
            WHEN 8 THEN 
                CASE WHEN (SS.freq_recurrence_factor > 1) 
                     THEN 'Every ' + CONVERT(VARCHAR(3), SS.freq_recurrence_factor) + ' Weeks'  
                     ELSE 'Weekly'  
                END
            WHEN 16 THEN 
                CASE WHEN (SS.freq_recurrence_factor > 1) 
                     THEN 'Every ' + CONVERT(VARCHAR(3), SS.freq_recurrence_factor) + ' Months' 
                     ELSE 'Monthly' 
                END
            WHEN 32 THEN 'Every ' + CONVERT(VARCHAR(3), SS.freq_recurrence_factor) + ' Months' -- RELATIVE
            WHEN 64 THEN 'SQL Startup'
            WHEN 128 THEN 'SQL Idle'
            ELSE '??'
        END AS Frequency,  
        CASE
            WHEN (freq_type = 1) THEN 'One time only'
            WHEN (freq_type = 4 AND freq_interval = 1) THEN 'Every Day'
            WHEN (freq_type = 4 AND freq_interval > 1) THEN 'Every ' + CONVERT(VARCHAR(10), freq_interval) + ' Days'
            WHEN (freq_type = 8) THEN (SELECT 'Weekly Schedule' = MIN(D1 + D2 + D3 + D4 + D5 + D6 + D7)
                                       FROM (
                                           SELECT SS.schedule_id,
                                                  freq_interval, 
                                                  'D1' = CASE WHEN (freq_interval & 1 <> 0) THEN 'Sun ' ELSE '' END,
                                                  'D2' = CASE WHEN (freq_interval & 2 <> 0) THEN 'Mon ' ELSE '' END,
                                                  'D3' = CASE WHEN (freq_interval & 4 <> 0) THEN 'Tue ' ELSE '' END,
                                                  'D4' = CASE WHEN (freq_interval & 8 <> 0) THEN 'Wed ' ELSE '' END,
                                                  'D5' = CASE WHEN (freq_interval & 16 <> 0) THEN 'Thu ' ELSE '' END,
                                                  'D6' = CASE WHEN (freq_interval & 32 <> 0) THEN 'Fri ' ELSE '' END,
                                                  'D7' = CASE WHEN (freq_interval & 64 <> 0) THEN 'Sat ' ELSE '' END
                                           FROM msdb..sysschedules SS
                                           WHERE freq_type = 8
                                       ) AS F
                                       WHERE schedule_id = SJ.schedule_id)
            WHEN (freq_type = 16) THEN 'Day ' + CONVERT(VARCHAR(2), freq_interval) 
            WHEN (freq_type = 32) THEN 
                (SELECT freq_rel + WDAY 
                 FROM (
                     SELECT SS.schedule_id,
                            'freq_rel' = CASE(freq_relative_interval)
                                WHEN 1 THEN 'First'
                                WHEN 2 THEN 'Second'
                                WHEN 4 THEN 'Third'
                                WHEN 8 THEN 'Fourth'
                                WHEN 16 THEN 'Last'
                                ELSE '??'
                            END,
                            'WDAY' = CASE (freq_interval)
                                WHEN 1 THEN ' Sun'
                                WHEN 2 THEN ' Mon'
                                WHEN 3 THEN ' Tue'
                                WHEN 4 THEN ' Wed'
                                WHEN 5 THEN ' Thu'
                                WHEN 6 THEN ' Fri'
                                WHEN 7 THEN ' Sat'
                                WHEN 8 THEN ' Day'
                                WHEN 9 THEN ' Weekday'
                                WHEN 10 THEN ' Weekend'
                                ELSE '??'
                            END
                     FROM msdb..sysschedules SS
                     WHERE SS.freq_type = 32
                 ) AS WS 
                 WHERE WS.schedule_id = SS.schedule_id) 
        END AS Interval,
        CASE (freq_subday_type)
            WHEN 1 THEN LEFT(STUFF(STUFF(REPLICATE('0', 6 - LEN(active_start_time)) + CONVERT(VARCHAR(6), active_start_time), 3, 0, ':'), 6, 0, ':'), 8)
            WHEN 2 THEN 'Every ' + CONVERT(VARCHAR(10), freq_subday_interval) + ' seconds'
            WHEN 4 THEN 'Every ' + CONVERT(VARCHAR(10), freq_subday_interval) + ' minutes'
            WHEN 8 THEN 'Every ' + CONVERT(VARCHAR(10), freq_subday_interval) + ' hours'
            ELSE '??'
        END AS [Time],
        CASE SJ.next_run_date
            WHEN 0 THEN CAST('n/a' AS CHAR(10))
            ELSE CONVERT(CHAR(10), CONVERT(DATETIME, CONVERT(CHAR(8), SJ.next_run_date)), 120) + ' ' + LEFT(STUFF(STUFF(REPLICATE('0', 6 - LEN(next_run_time)) + CONVERT(VARCHAR(6), next_run_time), 3, 0, ':'), 6, 0, ':'), 8)
        END AS NextRunTime,
        LastRunOutcome = CASE (SELECT TOP 1 jbh.run_status 
                               FROM msdb..sysjobhistory jbh 
                               WHERE jbh.step_id = 0 
                               AND jbh.job_id = S.job_id 
                               ORDER BY run_date DESC) 
                         WHEN 0 THEN 'Failed' 
                         WHEN 1 THEN 'Succeeded' 
                         WHEN 2 THEN 'Retry' 
                         WHEN 3 THEN 'Canceled' 
                         WHEN 4 THEN 'In Progress' 
                         ELSE '' 
                         END
    FROM msdb.dbo.sysjobs S
    LEFT JOIN msdb.dbo.sysjobschedules SJ ON S.job_id = SJ.job_id  
    LEFT JOIN msdb.dbo.sysschedules SS ON SS.schedule_id = SJ.schedule_id
    LEFT JOIN master.sys.syslogins l ON S.owner_sid = l.sid
) a
WHERE LastRunOutcome = 'Failed'
  AND IsEnabled = 'Enabled'
ORDER BY JobName;
"@


# List of Sysadmin account
$sysadminquery = @"
SELECT DISTINCT @@servername Server_Name, p.name AS [loginname] ,
p.type ,
p.type_desc ,
CONVERT(VARCHAR(10),p.create_date ,101) AS [created],
CONVERT(VARCHAR(10),p.modify_date , 101) AS [update]
FROM sys.server_principals p
JOIN sys.syslogins s ON p.sid = s.sid
JOIN sys.server_permissions sp ON p.principal_id = sp.grantee_principal_id
WHERE p.type_desc IN ('SQL_LOGIN', 'WINDOWS_LOGIN', 'WINDOWS_GROUP')
-- Logins that are not process logins
AND p.name NOT LIKE '##%' and p.name not in ('FACTENTRYUK\administrator','FACTENTRYUK\dba','sa','FACTENTRYUK\DBATeam')
-- Logins that are sysadmins or have GRANT CONTROL SERVER
AND (s.sysadmin = 1 OR sp.permission_name = 'CONTROL SERVER') and 
p.name not like 'NT%'
ORDER BY p.type,p.name 
GO

"@


# SQL Server Read_Only/Offline Database
$dbquery = @"
select @@SERVERNAME Server_Name , name, state_desc = case is_read_only  when 0 then 'OFFLINE' when 1 then 'READ_ONLY' end  
from sys.databases 
where state_desc='OFFLINE' or is_read_only=1
"@


# SQL Server MEMORY Utilisation Status - Improved Version
$memquery = @"
WITH MemoryMetrics AS (
    -- Get basic memory counters
    SELECT 
        counter_name,
        CASE 
            WHEN counter_name IN ('Total Server Memory (KB)', 'Target Server Memory (KB)')
            THEN ROUND(CAST(cntr_value AS FLOAT) / 1024 / 1024, 2)  -- Convert KB to GB
            ELSE cntr_value
        END AS cntr_value
    FROM sys.dm_os_performance_counters 
    WHERE [object_name] LIKE '%Memory Manager%' 
       AND counter_name IN ('Total Server Memory (KB)', 'Target Server Memory (KB)', 'Memory Grants Pending')
    
    UNION ALL
    
    -- Get Page Life Expectancy
    SELECT 
        counter_name,
        cntr_value
    FROM sys.dm_os_performance_counters 
    WHERE [object_name] LIKE '%Buffer Manager%' 
       AND counter_name = 'Page life expectancy'
),
ConfigMemory AS (
    -- Get configured memory limits
    SELECT 
        name,
        ROUND(CAST(value AS FLOAT) / 1024, 2) AS value_gb  -- Convert MB to GB
    FROM sys.configurations 
    WHERE name IN ('min server memory (MB)', 'max server memory (MB)')
),
SystemMemory AS (
    -- Get system memory information
    SELECT 
        ROUND(CAST(total_physical_memory_kb AS FLOAT) / 1024 / 1024, 2) AS total_physical_memory_gb,
        ROUND(CAST(available_physical_memory_kb AS FLOAT) / 1024 / 1024, 2) AS available_physical_memory_gb,
        ROUND(CAST(system_cache_kb AS FLOAT) / 1024 / 1024, 2) AS system_cache_gb,
        ROUND(CAST(kernel_paged_pool_kb AS FLOAT) / 1024 / 1024, 2) AS kernel_paged_pool_gb,
        ROUND(CAST(kernel_nonpaged_pool_kb AS FLOAT) / 1024 / 1024, 2) AS kernel_nonpaged_pool_gb
    FROM sys.dm_os_sys_memory
)
SELECT 
    @@SERVERNAME AS Server_Name,
    
    -- Memory Configuration
    (SELECT value_gb FROM ConfigMemory WHERE name = 'min server memory (MB)') AS MinServerMemory_GB,
    (SELECT value_gb FROM ConfigMemory WHERE name = 'max server memory (MB)') AS MaxServerMemory_GB,
    
    -- Current Memory Usage
    (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Total Server Memory (KB)') AS TotalServerMemory_GB,
    (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Target Server Memory (KB)') AS TargetServerMemory_GB,
    
    -- Memory Ratios and Percentages
    ROUND(
        (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Total Server Memory (KB)') * 100.0 /
        NULLIF((SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Target Server Memory (KB)'), 0), 2
    ) AS MemoryUsage_Percent,
    
    ROUND(
        (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Target Server Memory (KB)') * 100.0 /
        NULLIF((SELECT value_gb FROM ConfigMemory WHERE name = 'max server memory (MB)'), 0), 2
    ) AS TargetVsMax_Percent,
    
    -- Performance Indicators
    (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Page life expectancy') AS PageLifeExpectancy_Seconds,
    (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Memory Grants Pending') AS MemoryGrantsPending,
    
    -- System Memory
    sm.total_physical_memory_gb AS SystemTotalMemory_GB,
    sm.available_physical_memory_gb AS SystemAvailableMemory_GB,
    
    -- Memory Pressure Indicators
    CASE 
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Page life expectancy') < 300 THEN 'CRITICAL - Very Low PLE'
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Page life expectancy') < 600 THEN 'WARNING - Low PLE'
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Page life expectancy') > 1000 THEN 'GOOD - High PLE'
        ELSE 'OK - Normal PLE'
    END AS PageLifeStatus,
    
    CASE 
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Memory Grants Pending') > 0 THEN 'WARNING - Pending Grants'
        ELSE 'GOOD - No Pending Grants'
    END AS MemoryGrantStatus,
    
    CASE 
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Target Server Memory (KB)') >= 
             (SELECT value_gb FROM ConfigMemory WHERE name = 'max server memory (MB)') * 0.95 
        THEN 'WARNING - Near Max Memory'
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Total Server Memory (KB)') >= 
             (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Target Server Memory (KB)') * 0.95 
        THEN 'GOOD - Memory Available'
        ELSE 'OK - Normal Usage'
    END AS OverallMemoryStatus,
    
    -- Recommendations
    CASE 
        WHEN (SELECT value_gb FROM ConfigMemory WHERE name = 'max server memory (MB)') = 2147483647 
        THEN 'RECOMMENDATION: Set Max Server Memory - Currently Unlimited'
        WHEN (SELECT value_gb FROM ConfigMemory WHERE name = 'max server memory (MB)') > sm.total_physical_memory_gb * 0.9 
        THEN 'RECOMMENDATION: Reduce Max Server Memory - Too High for System'
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Page life expectancy') < 300 
        THEN 'RECOMMENDATION: Investigate Memory Pressure - Add RAM or Reduce Memory Usage'
        WHEN (SELECT cntr_value FROM MemoryMetrics WHERE counter_name = 'Memory Grants Pending') > 0 
        THEN 'RECOMMENDATION: Monitor Query Memory Usage - Possible Memory Contention'
        ELSE 'RECOMMENDATION: Memory Configuration Looks Good'
    END AS Recommendations

FROM SystemMemory sm;
"@



#Collecting Blocking sessions 
$deadlockquery = @"
  
declare @BlockingDurationThreshold smallint = 60;  
declare @BlockedSessionThreshold smallint = NULL;
 
SET NOCOUNT ON;  
--READ UNCOMMITTED, since we're dealing with blocking, we don't want to make things worse.  
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  
  
---Sure, it would work if you supplied both, but the ANDing of those gets confusing to people, so easier to just do this.  
IF ((@BlockingDurationThreshold IS NOT NULL AND @BlockedSessionThreshold IS NOT NULL)  
    OR COALESCE(@BlockingDurationThreshold, @BlockedSessionThreshold) IS NULL)  
BEGIN  
    RAISERROR('Must supply either @BlockingDurationThreshold or @BlockedSessionThreshold (but not both).',16,1);  
END;  
  
DECLARE @Id int = 1,  
        @Spid int = 0,  
        @JobIdHex nvarchar(34),  
        @JobName nvarchar(256),  
        @WaitResource nvarchar(256),  
        @DbName nvarchar(256),  
        @ObjectName nvarchar(256),  
        @IndexName nvarchar(256),  
        @Sql nvarchar(max);  
  
CREATE TABLE #Blocked (  
    ID int identity(1,1) PRIMARY KEY,  
    WaitingSpid smallint,  
    BlockingSpid smallint,  
    LeadingBlocker smallint,  
    BlockingChain nvarchar(4000),  
    DbName sysname,  
    HostName nvarchar(128),  
    ProgramName nvarchar(128),  
    LoginName nvarchar(128),  
    LoginTime datetime2(3),  
    LastRequestStart datetime2(3),  
    LastRequestEnd datetime2(3),  
    TransactionCnt int,  
    Command nvarchar(32),  
    WaitTime int,  
    WaitResource nvarchar(256),  
    WaitDescription nvarchar(1000),  
    SqlText nvarchar(max),  
    SqlStatement nvarchar(max),  
    InputBuffer nvarchar(4000),  
    SessionInfo XML,  
    );  
  
CREATE TABLE #InputBuffer (  
    EventType nvarchar(30),  
    Params smallint,  
    EventInfo nvarchar(4000)  
    );  
  
CREATE TABLE #LeadingBlocker (  
    Id int identity(1,1) PRIMARY KEY,  
    LeadingBlocker smallint,  
    BlockedSpidCount int,  
    DbName sysname,  
    HostName nvarchar(128),  
    ProgramName nvarchar(128),  
    LoginName nvarchar(128),  
    LoginTime datetime2(3),  
    LastRequestStart datetime2(3),  
    LastRequestEnd datetime2(3),  
    TransactionCnt int,  
    Command nvarchar(32),  
    WaitTime int,  
    WaitResource nvarchar(256),  
    WaitDescription nvarchar(1000),  
    SqlText nvarchar(max),  
    SqlStatement nvarchar(max),  
    InputBuffer nvarchar(4000),  
    SessionInfo xml,  
    );  
  
  
--Grab all sessions involved in Blocking (both blockers & waiters)  
  
INSERT INTO #Blocked (WaitingSpid, BlockingSpid, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart,   
                    LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement)  
-- WAITERS  
SELECT s.session_id AS WaitingSpid,   
       r.blocking_session_id AS BlockingSpid,  
       db_name(r.database_id) AS DbName,  
       s.host_name AS HostName,  
       s.program_name AS ProgramName,  
       s.login_name AS LoginName,  
       s.login_time AS LoginTime,  
       s.last_request_start_time AS LastRequestStart,  
       s.last_request_end_time AS LastRequestEnd,  
       -- Need to use sysprocesses for now until we're fully on 2012/2014  
       (SELECT TOP 1 sp.open_tran FROM master.sys.sysprocesses sp WHERE sp.spid = s.session_id) AS TransactionCnt,  
       --s.open_transaction_count AS TransactionCnt,  
       r.command AS Command,  
       r.wait_time AS WaitTime,  
       r.wait_resource AS WaitResource,  
       COALESCE(t.text,'') AS SqlText,  
       COALESCE(SUBSTRING(t.text, (r.statement_start_offset/2)+1, (  
                (CASE r.statement_end_offset  
                   WHEN -1 THEN DATALENGTH(t.text)  
                   ELSE r.statement_end_offset  
                 END - r.statement_start_offset)  
              /2) + 1),'') AS SqlStatement  
FROM sys.dm_exec_sessions s  
INNER JOIN sys.dm_exec_requests r ON r.session_id = s.session_id  
OUTER APPLY sys.dm_exec_sql_text (r.sql_handle) t  
WHERE r.blocking_session_id <> 0                --Blocked  
AND r.wait_time >= COALESCE(@BlockingDurationThreshold,0)*1000  
UNION   
-- BLOCKERS  
SELECT s.session_id AS WaitingSpid,   
       COALESCE(r.blocking_session_id,0) AS BlockingSpid,  
       COALESCE(db_name(r.database_id),'') AS DbName,  
       s.host_name AS HostName,  
       s.program_name AS ProgramName,  
       s.login_name AS LoginName,  
       s.login_time AS LoginTime,  
       s.last_request_start_time AS LastRequestStart,  
       s.last_request_end_time AS LastRequestEnd,  
       -- Need to use sysprocesses for now until we're fully on 2012/2014  
       (SELECT TOP 1 sp.open_tran FROM master.sys.sysprocesses sp WHERE sp.spid = s.session_id) AS TransactionCnt,  
       --s.open_transaction_count AS TransactionCnt,  
       COALESCE(r.command,'') AS Command,   
       COALESCE(r.wait_time,'') AS WaitTime,  
       COALESCE(r.wait_resource,'') AS WaitResource,  
       COALESCE(t.text,'') AS SqlText,  
       COALESCE(SUBSTRING(t.text, (r.statement_start_offset/2)+1, (  
                (CASE r.statement_end_offset  
                   WHEN -1 THEN DATALENGTH(t.text)  
                   ELSE r.statement_end_offset  
                 END - r.statement_start_offset)  
              /2) + 1),'') AS SqlStatement  
FROM sys.dm_exec_sessions s  
LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id  
OUTER APPLY sys.dm_exec_sql_text (r.sql_handle) t  
WHERE s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests ) --Blockers  
AND COALESCE(r.blocking_session_id,0) = 0;                  --Not blocked  
  
  
-- Grab the input buffer for all sessions, too.  
WHILE EXISTS (SELECT 1 FROM #Blocked WHERE InputBuffer IS NULL)  
BEGIN  
    TRUNCATE TABLE #InputBuffer;  
      
    SELECT TOP 1 @Spid = WaitingSpid, @ID = ID  
    FROM #Blocked  
    WHERE InputBuffer IS NULL;  
  
    SET @Sql = 'DBCC INPUTBUFFER (' + CAST(@Spid AS varchar(10)) + ');';  
  
    BEGIN TRY  
        INSERT INTO #InputBuffer  
        EXEC sp_executesql @sql;  
    END TRY  
    BEGIN CATCH  
        PRINT 'InputBuffer Failed';  
    END CATCH  
  
    --SELECT @id, @Spid, COALESCE((SELECT TOP 1 EventInfo FROM #InputBuffer),'')  
    --EXEC sp_executesql @sql;  
  
    UPDATE b  
    SET InputBuffer = COALESCE((SELECT TOP 1 EventInfo FROM #InputBuffer),'')  
    FROM #Blocked b  
    WHERE ID = @Id;  
END;  
  
--Convert Hex job_ids for SQL Agent jobs to names.  
WHILE EXISTS(SELECT 1 FROM #Blocked WHERE ProgramName LIKE 'SQLAgent - TSQL JobStep (Job 0x%')  
BEGIN  
    SELECT @JobIdHex = '', @JobName = '';  
  
    SELECT TOP 1 @ID = ID,   
            @JobIdHex =  SUBSTRING(ProgramName,30,34)  
    FROM #Blocked  
    WHERE ProgramName LIKE 'SQLAgent - TSQL JobStep (Job 0x%';  
  
    SELECT @Sql = N'SELECT @JobName = name FROM msdb.dbo.sysjobs WHERE job_id = ' + @JobIdHex;  
    EXEC sp_executesql @Sql, N'@JobName nvarchar(256) OUT', @JobName = @JobName OUT;  
  
    UPDATE b  
    SET ProgramName = LEFT(REPLACE(ProgramName,@JobIdHex,@JobName),128)  
    FROM #Blocked b  
    WHERE ID = @Id;  
END;  
  
--Decypher wait resources.  
DECLARE wait_cur CURSOR FOR  
    SELECT WaitingSpid, WaitResource FROM #Blocked WHERE WaitResource <> '';  
  
OPEN wait_cur;  
FETCH NEXT FROM wait_cur INTO @Spid, @WaitResource;  
WHILE @@FETCH_STATUS = 0  
BEGIN  
    IF @WaitResource LIKE 'KEY%'  
    BEGIN  
        --Decypher DB portion of wait resource  
        SET @WaitResource = LTRIM(REPLACE(@WaitResource,'KEY:',''));  
        SET @DbName = db_name(SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource)));  
        --now get the object name  
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256);  
        SELECT @Sql = 'SELECT @ObjectName = SCHEMA_NAME(o.schema_id) + ''.'' + o.name, @IndexName = i.name ' +  
            'FROM ' + QUOTENAME(@DbName) + '.sys.partitions p ' +  
            'JOIN ' + QUOTENAME(@DbName) + '.sys.objects o ON p.OBJECT_ID = o.OBJECT_ID ' +  
            'JOIN ' + QUOTENAME(@DbName) + '.sys.indexes i ON p.OBJECT_ID = i.OBJECT_ID  AND p.index_id = i.index_id ' +  
            'WHERE p.hobt_id = SUBSTRING(@WaitResource,0,CHARINDEX('' '',@WaitResource))'  
        EXEC sp_executesql @sql,N'@WaitResource nvarchar(256),@ObjectName nvarchar(256) OUT,@IndexName nvarchar(256) OUT',  
                @WaitResource = @WaitResource, @ObjectName = @ObjectName OUT, @IndexName = @IndexName OUT  
        --now populate the WaitDescription column  
        UPDATE b  
        SET WaitDescription = 'KEY WAIT: ' + @DbName + '.' + @ObjectName + ' (' + COALESCE(@IndexName,'') + ')'  
        FROM #Blocked b  
        WHERE WaitingSpid = @Spid;  
    END;  
    ELSE IF @WaitResource LIKE 'OBJECT%'  
    BEGIN  
        --Decypher DB portion of wait resource  
        SET @WaitResource = LTRIM(REPLACE(@WaitResource,'OBJECT:',''));  
        SET @DbName = db_name(SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource)));  
        --now get the object name  
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256);  
        SET @Sql = 'SELECT @ObjectName = schema_name(schema_id) + ''.'' + name FROM [' + @DbName + '].sys.objects WHERE object_id = SUBSTRING(@WaitResource,0,CHARINDEX('':'',@WaitResource))';  
        EXEC sp_executesql @sql,N'@WaitResource nvarchar(256),@ObjectName nvarchar(256) OUT',@WaitResource = @WaitResource, @ObjectName = @ObjectName OUT;  
        --Now populate the WaitDescription column  
        UPDATE b  
        SET WaitDescription = 'OBJECT WAIT: ' + @DbName + '.' + @ObjectName  
        FROM #Blocked b  
        WHERE WaitingSpid = @Spid;  
    END;  
    ELSE IF (@WaitResource LIKE 'PAGE%' OR @WaitResource LIKE 'RID%')  
    BEGIN  
        --Decypher DB portion of wait resource  
        SELECT @WaitResource = LTRIM(REPLACE(@WaitResource,'PAGE:',''));  
        SELECT @WaitResource = LTRIM(REPLACE(@WaitResource,'RID:',''));  
        SET @DbName = db_name(SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource)));  
        --now get the file name  
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256)  
        SELECT @ObjectName = name   
        FROM sys.master_files  
        WHERE database_id = db_id(@DbName)  
        AND file_id = SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource));  
        --Now populate the WaitDescription column  
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256)  
        IF @WaitResource LIKE '%:%'  
        BEGIN  
            UPDATE b  
            SET WaitDescription = 'ROW WAIT: ' + @DbName + ' File: ' + @ObjectName + ' Page_id/Slot: ' + @WaitResource  
            FROM #Blocked b  
            WHERE WaitingSpid = @Spid;  
        END;  
        ELSE  
        BEGIN  
            UPDATE b  
            SET WaitDescription = 'PAGE WAIT: ' + @DbName + ' File: ' + @ObjectName + ' Page_id: ' + @WaitResource  
            FROM #Blocked b  
            WHERE WaitingSpid = @Spid;  
        END;  
    END;  
    FETCH NEXT FROM wait_cur INTO @Spid, @WaitResource;  
END;  
CLOSE wait_cur;  
DEALLOCATE wait_cur;  
  
  
--Move the LEADING blockers out to their own table.  
INSERT INTO #LeadingBlocker (LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, LastRequestEnd,   
                    TransactionCnt, Command, WaitTime, WaitResource, WaitDescription, SqlText, SqlStatement, InputBuffer)  
SELECT WaitingSpid, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, LastRequestEnd,   
                    TransactionCnt, Command, WaitTime, WaitResource, WaitDescription, SqlText, SqlStatement, InputBuffer  
FROM #Blocked b  
WHERE BlockingSpid = 0  
AND EXISTS (SELECT 1 FROM #Blocked b1 WHERE b1.BlockingSpid = b.WaitingSpid);  
  
DELETE FROM #Blocked WHERE BlockingSpid = 0;  
  
--Update #Blocked to include LeadingBlocker & BlockingChain  
WITH BlockingChain AS (  
    SELECT LeadingBlocker AS Spid,   
           CAST(0 AS smallint) AS Blocker,  
           CAST(LeadingBlocker AS nvarchar(4000)) AS BlockingChain,   
           LeadingBlocker AS LeadingBlocker  
    FROM #LeadingBlocker  
    UNION ALL  
    SELECT b.WaitingSpid AS Spid,   
           b.BlockingSpid AS Blocker,  
           RIGHT((CAST(b.WaitingSpid AS nvarchar(10)) + N' ' + CHAR(187) + N' ' + bc.BlockingChain),4000) AS BlockingChain,  
           bc.LeadingBlocker  
    FROM #Blocked b  
    JOIN BlockingChain bc ON bc.Spid = b.BlockingSpid  
    )  
UPDATE b  
SET LeadingBlocker = bc.LeadingBlocker,  
    BlockingChain = bc.BlockingChain  
FROM #Blocked b  
JOIN BlockingChain bc ON b.WaitingSpid = bc.Spid;  
  
-- Populate BlockedSpidCount for #LeadingBlocker  
UPDATE lb  
SET BlockedSpidCount = cnt.BlockedSpidCount  
FROM #LeadingBlocker lb  
JOIN (SELECT LeadingBlocker, COUNT(*) BlockedSpidCount FROM #Blocked GROUP BY LeadingBlocker) cnt   
        ON cnt.LeadingBlocker = lb.LeadingBlocker;  
  
  
-- Populate SessionInfo column with HTML details for sending email  
-- Since there's a bunch of logic here, code is more readable doing this separate than mashing it in with the rest of HTML email creation  
  
UPDATE lb  
SET SessionInfo = (SELECT LeadingBlocker,  
                          LoginName,   
                          TransactionCnt,   
                          WaitResource = COALESCE(WaitDescription,WaitResource),  
                          HostName,  
                          DbName,  
                          LastRequest = CONVERT(varchar(20),LastRequestStart,20),  
                          ProgramName,  
                          InputBuffer,  
                          SqlStatement,  
                          SqlText  
                    FROM #LeadingBlocker lb2   
                    WHERE lb.id = lb2.id   
                    FOR XML PATH ('LeadBlocker'))  
FROM #LeadingBlocker lb;  
  
  
/*UPDATE b  
SET SessionInfo = '<LoginName>' + LoginName + '</LoginName>' +  
                  '<HostName>' + HostName + '</HostName>' +  
                  CASE WHEN TransactionCnt <> 0   
                    THEN '<TransactionCnt>' + CAST(TransactionCnt AS nvarchar(10)) + '</TransactionCnt>'   
                    ELSE ''  
                  END +  
                  CASE WHEN WaitResource <> ''  
                    THEN '<WaitResource>' + COALESCE(WaitDescription,WaitResource) + '</WaitResource>'   
                    ELSE ''  
                  END +  
                  '<DbName>' + DbName + '</DbName>' +  
                  '<LastRequest>' + CONVERT(varchar(20),LastRequestStart,20) + '</LastRequest>' +  
                  '<ProgramName>' + ProgramName + '</ProgramName>'  
FROM #Blocked b;  
*/  
UPDATE b  
SET SessionInfo = (SELECT WaitingSpid,  
                          BlockingChain,  
                          LoginName,   
                          TransactionCnt,   
                          WaitResource = COALESCE(WaitDescription,WaitResource),  
                          HostName,  
                          DbName,  
                          LastRequest = CONVERT(varchar(20),LastRequestStart,20),  
                          ProgramName,  
                          InputBuffer,  
                          SqlStatement,  
                          SqlText  
                    FROM #Blocked b2   
                    WHERE b.id = b2.id   
                    FOR XML PATH ('BlockedSession'))  
FROM #Blocked b;  
  
--output results  
    IF NOT EXISTS (SELECT 1 FROM #LeadingBlocker WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount))  
        SELECT @@SERVERNAME servername, 'No Blocking Detected' AS Blocking;  
    ELSE  
    BEGIN  
        --SELECT * FROM #LeadingBlocker   
        --WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount)  
        --ORDER BY LoginTime;  
        ----  
        --SELECT * FROM #Blocked b  
        --WHERE EXISTS (SELECT 1 FROM #LeadingBlocker lb   
        --                WHERE lb.LeadingBlocker = b.LeadingBlocker  
        --                AND lb.BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,lb.BlockedSpidCount))  
        --ORDER BY b.WaitTime DESC;  
		select @@SERVERNAME servername,'Blocking Detected' AS Blocking,a.HostName,b.DbName,a.LoginName,a.LeadingBlocker,b.WaitingSpid,b.Command ,a.LoginTime,a.LastRequestStart,a.LastRequestEnd,b.BlockingChain,b.WaitResource,a.SqlText [leading_statement],b.InputBuffer[waiting_query],a.SessionInfo
		FROM #LeadingBlocker a, #Blocked b
    END; 
	 
	drop table #Blocked
	drop table #InputBuffer
	drop table #LeadingBlocker
"@

$tempquery = @"
	--Tempdb file usage information
set nocount on
Create table #tempdbfileusage(               
servername varchar(100),                           
databasename varchar(100),                           
filename varchar(100),                           
physicalName varchar(100),                           
filesizeMB int,                           
availableSpaceMB int,                           
percentfull int   
)   
  
DECLARE @TEMPDBSQL NVARCHAR(4000);  
SET @TEMPDBSQL = ' USE Tempdb;  
SELECT  CONVERT(VARCHAR(100), @@SERVERNAME) AS [server_name]  
                ,db.name AS [database_name]  
                ,mf.[name] AS [file_logical_name]  
                ,mf.[filename] AS[file_physical_name]  
                ,convert(FLOAT, mf.[size]/128) AS [file_size_mb]               
                ,convert(FLOAT, (mf.[size]/128 - (CAST(FILEPROPERTY(mf.[name], ''SpaceUsed'') AS int)/128))) as [available_space_mb]  
                ,convert(DECIMAL(38,2), (CAST(FILEPROPERTY(mf.[name], ''SpaceUsed'') AS int)/128.0)/(mf.[size]/128.0))*100 as [percent_full]      
FROM   tempdb.dbo.sysfiles mf  
JOIN      master..sysdatabases db  
ON         db.dbid = db_id()';  
--PRINT @TEMPDBSQL;  
insert into #tempdbfileusage  
EXEC SP_EXECUTESQL @TEMPDBSQL; 
if (select max(percentfull) from #tempdbfileusage) >=50.00
select 'Tempdb Running OUT OF Threshold' [status], * from #tempdbfileusage
else 
select @@SERVERNAME servername,'Tempdb' databasename,avg(filesizeMB) filesizeMB,avg(availableSpaceMB) availableSpaceMB,avg(percentfull) percentfull,'Tempdb Running Within the Threshold' [status] from #tempdbfileusage 
drop table #tempdbfileusage
	
"@


#Linkedserver

$linkedserverquery = @" 
SELECT @@servername servername,a.server_id,a.name,a.product,a.provider,a.data_source,a.location,a.provider_string
        FROM sys.Servers a
        LEFT OUTER JOIN sys.linked_logins b ON b.server_id = a.server_id
        LEFT OUTER JOIN sys.server_principals c ON c.principal_id = b.local_principal_id
"@

$URquery = @"
SELECT DISTINCT
    SERVERPROPERTY('servername') AS ServerName
"@

$instanceleveldbgrowthquery = @"
DECLARE @endDate DATETIME, @startDate DATETIME, @currentMonth INT;
SET @endDate = GETDATE();  -- Current date
SET @startDate = DATEFROMPARTS(YEAR(@endDate), 1, 1);  -- Start of the current year
SET @currentMonth = DATEPART(MM, @endDate);  -- Get the current month

;WITH HIST AS
(
    SELECT 
        MONTH(BS.backup_start_date) AS Month,
        CONVERT(NUMERIC(10, 2), AVG(BF.file_size / 1048576.0)) AS AvgSizeMB
    FROM msdb.dbo.backupset AS BS
    INNER JOIN msdb.dbo.backupfile AS BF
        ON BS.backup_set_id = BF.backup_set_id
    WHERE 
        BS.database_name NOT IN ('master', 'msdb', 'model', 'tempdb')
        AND BF.file_type = 'D'
        AND BS.backup_start_date BETWEEN @startDate AND @endDate
    GROUP BY 
        MONTH(BS.backup_start_date)
),
PIVOTED AS
(
    SELECT 
        ISNULL([1], 0) AS January,
        ISNULL([2], 0) AS February,
        ISNULL([3], 0) AS March,
        ISNULL([4], 0) AS April,
        ISNULL([5], 0) AS May,
        ISNULL([6], 0) AS June,
        ISNULL([7], 0) AS July,
        ISNULL([8], 0) AS August,
        ISNULL([9], 0) AS September,
        ISNULL([10], 0) AS October,
        ISNULL([11], 0) AS November,
        ISNULL([12], 0) AS December
    FROM
        (SELECT 
            Month,
            AvgSizeMB
        FROM HIST
        ) AS SourceTable
    PIVOT
    (
        SUM(AvgSizeMB)
        FOR Month IN ([1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [11], [12])
    ) AS PivotTable
),
EarliestMonth AS
(
    SELECT
        CASE 
            WHEN January > 0 THEN 1
            WHEN February > 0 THEN 2
            WHEN March > 0 THEN 3
            WHEN April > 0 THEN 4
            WHEN May > 0 THEN 5
            WHEN June > 0 THEN 6
            WHEN July > 0 THEN 7
            WHEN August > 0 THEN 8
            WHEN September > 0 THEN 9
            WHEN October > 0 THEN 10
            WHEN November > 0 THEN 11
            WHEN December > 0 THEN 12
            ELSE NULL
        END AS EarliestAvailableMonth,
        CASE 
            WHEN January > 0 THEN January
            WHEN February > 0 THEN February
            WHEN March > 0 THEN March
            WHEN April > 0 THEN April
            WHEN May > 0 THEN May
            WHEN June > 0 THEN June
            WHEN July > 0 THEN July
            WHEN August > 0 THEN August
            WHEN September > 0 THEN September
            WHEN October > 0 THEN October
            WHEN November > 0 THEN November
            WHEN December > 0 THEN December
            ELSE NULL
        END AS EarliestMonthSize
    FROM 
        PIVOTED
),
CurrentMonthData AS
(
    SELECT 
        CASE @currentMonth 
            WHEN 1 THEN January
            WHEN 2 THEN February
            WHEN 3 THEN March
            WHEN 4 THEN April
            WHEN 5 THEN May
            WHEN 6 THEN June
            WHEN 7 THEN July
            WHEN 8 THEN August
            WHEN 9 THEN September
            WHEN 10 THEN October
            WHEN 11 THEN November
            WHEN 12 THEN December
        END AS CurrentMonthSize
    FROM 
        PIVOTED
),
Growth AS
(
    SELECT 
        CASE 
            WHEN EarliestMonthSize > 0 THEN FORMAT(
                ((CurrentMonthSize - EarliestMonthSize) / NULLIF(EarliestMonthSize, 0)) * 100, '0.00')
            ELSE 'N/A'
        END AS GrowthPercentage
    FROM 
        CurrentMonthData
    CROSS JOIN
        EarliestMonth
)
SELECT 
    @@SERVERNAME AS ServerName,
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
    GrowthPercentage
FROM 
    PIVOTED
CROSS JOIN 
    Growth
ORDER BY 
    ServerName;


"@

$NewlyCretedJobsq = @"
SELECT  j.name AS job_name, j.date_created,
    CASE 
        WHEN j.enabled = 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS job_status,
    CASE 
        WHEN h.run_status = 1 THEN 'Success'
        WHEN h.run_status = 0 THEN 'Failure'
        WHEN h.run_status = 4 THEN 'Running'
        ELSE 'Other'
    END AS last_run_status,
    h.run_date AS last_run_date,
    CAST(
        ROUND(
            (ISNULL(h.run_duration / 10000, 0) * 60 +               -- Hours to minutes
             ISNULL((h.run_duration % 10000) / 100, 0) +            -- Minutes
             ISNULL(h.run_duration % 100, 0) / 60.0                 -- Seconds to minutes
            ), 2
        ) AS DECIMAL(10, 2)
    ) AS last_run_duration_in_minutes,
    s.name AS schedule_name,
    CASE 
        WHEN s.enabled = 1 THEN 'Yes'
        ELSE 'No'
    END AS schedule_enabled
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id
    AND h.instance_id = ( SELECT MAX(instance_id) FROM msdb.dbo.sysjobhistory WHERE job_id = j.job_id )
LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
LEFT JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
WHERE CONVERT(date, j.date_created) = CONVERT(date, DATEADD(day, -1, GETDATE()))
ORDER BY j.date_created;

"@


$tableover10GBquery = @"
-- Create a temporary table to store results from all databases
CREATE TABLE #TableSizeInfo (
    Server_Name NVARCHAR(128),
    Database_Name NVARCHAR(128),
    Schema_Name NVARCHAR(128),
    Table_Name NVARCHAR(128),
    GB DECIMAL(18, 2),
    Compression NVARCHAR(128)
);

DECLARE @SQL NVARCHAR(MAX) = N'';

-- Generate the SQL to get the table info from all databases
SELECT @SQL = @SQL + '
USE [' + name + '];
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

INSERT INTO #TableSizeInfo (Server_Name, Database_Name, Schema_Name, Table_Name, GB, Compression)
SELECT 
    @@SERVERNAME AS Server_Name,
    ''' + name + ''' AS Database_Name,
    OBJECT_SCHEMA_NAME(t.object_id) AS Schema_Name,
    t.name AS Table_Name,
    (
        SELECT SUM(a.total_pages) / 128 / 1024
        FROM sys.partitions AS p
        INNER JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
        WHERE p.object_id = t.object_id
    ) AS GB,
    (
        SELECT CASE 
                    WHEN MAX([data_compression]) = 0 
                        THEN ''Uncompressed''
                    WHEN MIN([data_compression]) = 0 AND MAX([data_compression]) > 0
                        THEN ''Partially Compressed''
                    WHEN MIN([data_compression]) = 1 AND MAX([data_compression]) = 1
                        THEN ''Row Compressed''
                    WHEN MIN([data_compression]) = 2 AND MAX([data_compression]) = 2
                        THEN ''Page Compressed''
                    WHEN MIN([data_compression]) = 1 AND MAX([data_compression]) = 2
                        THEN ''Row & Page Compressed''
                    WHEN MIN([data_compression]) IN (3,4)
                        THEN ''ColumnStore Compression''
                END
        FROM sys.partitions p
        INNER JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
        WHERE p.object_id = t.object_id
    ) AS Compression
FROM sys.tables t
GROUP BY 
    t.name,
    t.object_id
HAVING (
    SELECT SUM(a.total_pages) / 128 / 1024
    FROM sys.partitions AS p
    INNER JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
    WHERE p.object_id = t.object_id
) > 10
ORDER BY GB DESC;
' 
FROM sys.databases
WHERE state_desc = 'ONLINE' AND name NOT IN ('master', 'tempdb', 'model', 'msdb'); -- Exclude system databases if necessary

-- Execute the generated SQL
EXEC sp_executesql @SQL;

-- Select the results from the temporary table
SELECT * FROM #TableSizeInfo
ORDER BY GB DESC;

-- Drop the temporary table
DROP TABLE #TableSizeInfo;

"@




# Collect data
$data = @()
$service = @()
$hainfo = @()
$job = @()
$backupData = @()
$cpudata = @()
$diskdata = @()
$db = @()
$sysadmin = @()
$memdata = @()
$deadlockdata = @()
$tempdata = @()
$errorlogdata = @()
$linkedserverdata = @()
$serverStatus = @()
$URSdata  = @()
$tableover10data  = @()
$offlineServers = @()
$dbgrowthdata = @()
$NewlyCretedJobs = @()
$mirroring=@()
$Replication=@()
$Logshipping=@()
$AlwaysOn=@()

foreach ($server in $servers) 
{
    $connectionString = "Server=$server;Database=master;Integrated Security=True;"
    
    $tableover10GBquery
    # Collect tableover10DBdata
    try {
    $10GBresult = Invoke-Sqlcmd -Query $tableover10GBquery -ConnectionString $connectionString -ErrorAction Stop
    $tableover10data += $10GBresult
    } catch {
            }

    #NewlyCretedJobs
    
    try {
    $NewlyCretedJobsresult = Invoke-Sqlcmd -Query $NewlyCretedJobsq -ConnectionString $connectionString -ErrorAction Stop
    $NewlyCretedJobs += $NewlyCretedJobsresult
    } catch {
            }

    #Instancelevel DB growth
    
    try {
    $dbgrowthresult = Invoke-Sqlcmd -Query $instanceleveldbgrowthquery -ConnectionString $connectionString -ErrorAction Stop
    $dbgrowthdata += $dbgrowthresult
    } catch {
            }

    # Collect server Deadlock metrics
    try {
    $deadlockresult = Invoke-Sqlcmd -Query $deadlockquery -ConnectionString $connectionString -ErrorAction Stop
    $deadlockdata += $deadlockresult
    } catch {
            }

    # Collect Linkedserver metrics
    try {
    $linkedserveresult = Invoke-Sqlcmd -Query $linkedserverquery -ConnectionString $connectionString -ErrorAction Stop
    $linkedserverdata += $linkedserveresult
    } catch {
            }

    # Collect server Errorlog metrics
    try {
    $errorlogresult = Invoke-Sqlcmd -Query $errorlogquery -ConnectionString $connectionString -ErrorAction Stop
    $errorlogdata += $errorlogresult
    } catch {
            }

    # Collect server Memory metrics
    try {
    $memresult = Invoke-Sqlcmd -Query $memquery -ConnectionString $connectionString -ErrorAction Stop
    $memdata += $memresult
    } catch {
            }

    # Collect server metrics
    #try {
    #$result = Invoke-Sqlcmd -Query $query -ConnectionString $connectionString -ErrorAction Stop
    #$data += $result
    #} catch {
    #        }

    # Collect sysadmin accounts
    try {
    $sysadminresult = Invoke-Sqlcmd -Query $sysadminquery -ConnectionString $connectionString -ErrorAction Stop
    $sysadmin += $sysadminresult
    } catch {
            }

     # Collect server metrics
     try {
    $dbresult = Invoke-Sqlcmd -Query $dbquery -ConnectionString $connectionString -ErrorAction Stop
    $db += $dbresult
    } catch {
            }

    # Collect service metrics
    try {
    $serviceresult = Get-Service -Name "*SQL*","*SSIS*","*SSRS*","*ReportServer*","*MsDtsServer*","*MSOLAP*","*SQLAgent*","*SQLBrowser*","*SQLWriter*" -ErrorAction SilentlyContinue | 
        Select-Object @{N='Server_Name';E={$server}}, 
                      @{N='ServiceName';E={$_.DisplayName}}, 
                      @{N='StartUpType';E={
                          try {
                              $svc = Get-WmiObject Win32_Service -Filter "Name='$($_.Name)'" -ErrorAction SilentlyContinue
                              if ($svc) { $svc.StartMode } else { 'Unknown' }
                          } catch { 'Unknown' }
                      }}, 
                      @{N='Status';E={$_.Status}}, 
                      @{N='LastStartup';E={
                          try {
                              $svc = Get-WmiObject Win32_Service -Filter "Name='$($_.Name)'" -ErrorAction SilentlyContinue
                              if ($svc -and $svc.State -eq 'Running') {
                                  $proc = Get-Process -Name $_.Name -ErrorAction SilentlyContinue
                                  if ($proc) { $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                              } else { 'Service Stopped' }
                          } catch { 'N/A' }
                      }}, 
                      @{N='Account';E={
                          try {
                              $svc = Get-WmiObject Win32_Service -Filter "Name='$($_.Name)'" -ErrorAction SilentlyContinue
                              if ($svc) { $svc.StartName } else { 'Unknown' }
                          } catch { 'Unknown' }
                      }} |
        Sort-Object ServiceName
    $service += $serviceresult
} catch {
}

    # Collect Job metrics
    try {
    $jobresult = Invoke-Sqlcmd -Query $jobquery -ConnectionString $connectionString -ErrorAction Stop
    $job += $jobresult
    } catch {
            }

    # HA information
    try {
    $haresult = Invoke-Sqlcmd -Query $haquery -ConnectionString $connectionString -ErrorAction Stop
    $hainfo += $haresult
    } catch {
            }       
    
    # Collect backup report
    try {
    $backupResult = Invoke-Sqlcmd -Query $backupQuery -ConnectionString $connectionString -ErrorAction Stop
    $backupData += $backupResult
    } catch {
            }

    # Collect CPU report
    try {
    $cpuResult = Invoke-Sqlcmd -Query $cpu -ConnectionString $connectionString -ErrorAction Stop
    $cpudata += $cpuResult
    } catch {
            }

    # Collect DISK report
    try {
    $diskResult = Invoke-Sqlcmd -Query $diskquery -ConnectionString $connectionString -ErrorAction Stop
    $diskdata += $diskResult
    } catch {
            }

    # Collect server metrics
    try {
    $tempresult = Invoke-Sqlcmd -Query $tempquery -ConnectionString $connectionString -ErrorAction Stop
    $tempdata += $tempresult
    } catch {
            }

        # Collect server Log Shipping
    try {
    $Logshipp = Invoke-Sqlcmd -Query $Logship -ConnectionString $connectionString -ErrorAction Stop
    $Logshipping += $Logshipp
    } catch {
            }
        # Collect server Always ON
    try {
    $AOAG = Invoke-Sqlcmd -Query $Always_ON -ConnectionString $connectionString -ErrorAction Stop
    $AlwaysOn += $AOAG
    } catch {
            }
   
       # Collect server mirroing
    try {
    $mirr = Invoke-Sqlcmd -Query $mirror -ConnectionString $connectionString -ErrorAction Stop
    $mirroring += $mirr
    } catch {
            }


       # Collect server Replication
    try {
    $Repli = Invoke-Sqlcmd -Query $Repl -ConnectionString $connectionString -ErrorAction Stop
    $Replication += $Repli
    } catch {
            }

}

# Check each server's availability
# Collect data for each server
foreach ($server in $servers) 
{
    $connectionString = "Server=$server;Database=master;Integrated Security=True;"
    
    try {
        $result = Invoke-Sqlcmd -Query $query -ConnectionString $connectionString -ErrorAction Stop
        $data += $result
    } catch {
        # If server is unreachable, add to offline servers list
        $offlineServers += [PSCustomObject]@{
            ServerName = $server
            Status = "Offline"
        }
    }
}







# Convert data to HTML
$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Server Health Check Report</title>
    <meta http-equiv="refresh" content="160">
    <style>
        body { font-family: Arial, sans-serif; }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #ddd; padding: 8px; }
        th { background-color: #AFB7BF; }
        .critical { background-color: #ffcccc; }
        .warning { background-color: #ffffcc; }
        .good { background-color: #ccffcc; }
        td.status-offline { background-color: red; } /*  Red */
    </style>
</head>
<body>
    <h1 style="color: #394655;"> SQL Server Heatlh Check Report</h1>

    <p>Report generated on: $(Get-Date)</p>
    <h2 style="color: #DF9229;">Server Metrics</h2>
    <table>
        <tr>
            <th>Server</th>
            <th>Status</th>
            <th>SQL_Version</th>
            <th>SQL Version</th>
            <th>Product Level</th>
            <th>Edition</th>
            <th>Online Databases</th>
            <th>Active Requests</th>            
            <th>No_Of_Processors</th>
            <th>Tot_DB_Size_GB</th>
            <th>TotPhysicalMemory</th>
            <th>SQL Memory(MB)</th>
        </tr>
"@

foreach ($row in $data) {
switch ($row.Status) {
        "Critical" { $statusColor = "red" }
        "Offline" { $statusColor = "red" }
        "Stopped" { $statusColor = "red" }
        "Warning" { $statusColor = "yellow" }
        "Good" { $statusColor = "green" }
        "Running" { $statusColor = "lightgreen" }
        "Online" { $statusColor = "lightgreen" }
    }
    $html += "<tr>"
    $html += "<td>$($row.ServerName)</td>"
    $html += "<td style='background-color: $statusColor;'>$($row.Status)</td>"
    $html += "<td>$($row.SQL_Version)</td>"
    $html += "<td>$($row.SQLVersion)</td>"
    $html += "<td>$($row.ProductLevel)</td>"
    $html += "<td>$($row.Edition)</td>"
    $html += "<td style='text-align: center;'>$($row.OnlineDatabases)</td>"    
    $html += "<td style='text-align: center;'>$($row.ActiveRequests)</td>"    
    $html += "<td style='text-align: center;'>$($row.No_Of_Processors)</td>"
    $html += "<td style='text-align: right;'>$($row.Tot_DB_Size_GB)</td>"
    $html += "<td style='text-align: right;'>$($row.TotPhysicalMemory)</td>"
    $html += "<td style='text-align: right;'>$($row.SQL_Memory)</td>"
    $html += "</tr>"
}


#Instance level db growth
$html += @"
    </table>
    <h2 style="color: #DF9229;">Instance Level Databse Growth</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>January</th>
            <th>February</th>
            <th>March</th>
            <th>April</th>
            <th>May</th>
            <th>June</th>
            <th>July</th>
            <th>August</th>
            <th>September</th>
            <th>October</th>
            <th>November</th>
            <th>December</th>
            <th>GrowthPercentage</th>                     
        </tr>
"@
					
foreach ($row in $dbgrowthdata) {

    $html += "<tr>"
    $html += "<td>$($row.ServerName)</td>"
    $html += "<td style='text-align: right;'>$($row.January)</td>"
    $html += "<td style='text-align: right;'>$($row.February)</td>"
    $html += "<td style='text-align: right;'>$($row.March)</td>"
    $html += "<td style='text-align: right;'>$($row.April)</td>"
    $html += "<td style='text-align: right;'>$($row.May)</td>"
    $html += "<td style='text-align: right;'>$($row.June)</td>"
    $html += "<td style='text-align: right;'>$($row.July)</td>"
    $html += "<td style='text-align: right;'>$($row.August)</td>"
    $html += "<td style='text-align: right;'>$($row.September)</td>"
    $html += "<td style='text-align: right;'>$($row.October)</td>"
    $html += "<td style='text-align: right;'>$($row.November)</td>"
    $html += "<td style='text-align: right;'>$($row.December)</td>"
    $html += "<td style='text-align: right;'>$($row.GrowthPercentage)</td>" 
    $html += "</tr>"
}
#ServerName	January	February	March	April	May	June	July	August	September	October	November	December	GrowthPercentage

#Service status table
$html += @"
    </table>
    <h2 style="color: #DF9229;">SQL Server Service Status</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Service Name</th>
            <th>StartUp Type</th>
            <th>Status</th>
            <th>Last Startup</th>
            <th>Account</th>         
        </tr>
"@

foreach ($row in $service) {
    $statusColor = ""
    $textColor = "black"
    
    switch ($row.Status) {
        "Critical" { 
            $statusColor = "#FF4444"
            $textColor = "white"
        }
        "Offline" { 
            $statusColor = "#FF4444"
            $textColor = "white"
        }
        "Stopped" { 
            $statusColor = "#FF6B6B"
            $textColor = "white"
        }
        "Warning" { 
            $statusColor = "#FFD93D"
            $textColor = "black"
        }
        "Good" { 
            $statusColor = "#6BCF7F"
            $textColor = "white"
        }
        "Running" { 
            $statusColor = "#4CAF50"
            $textColor = "white"
        }
        "Online" { 
            $statusColor = "#4CAF50"
            $textColor = "white"
        }
        "Paused" { 
            $statusColor = "#FF9800"
            $textColor = "white"
        }
        "Starting" { 
            $statusColor = "#2196F3"
            $textColor = "white"
        }
        "Stopping" { 
            $statusColor = "#9E9E9E"
            $textColor = "white"
        }
        default { 
            $statusColor = "#F5F5F5"
            $textColor = "black"
        }
    }
    
    $html += "<tr>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td>$($row.ServiceName)</td>"
    $html += "<td style='text-align: center;'>$($row.StartUpType)</td>"
    $html += "<td style='background-color: $statusColor; color: $textColor; text-align: center; font-weight: bold;'>$($row.Status)</td>"
    $html += "<td>$($row.LastStartup)</td>"
    $html += "<td>$($row.Account)</td>"       
    $html += "</tr>"
}

#Read-Only/Offline Database list
$html += @"
    </table>
    <h2 style="color: #DF9229;">Read-Only/Offline Database list</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Database Name</th>
            <th>Status</th>                      					
        </tr>
"@
		
foreach ($row in $db) {
    switch ($row.state_desc) {
        "Critical" { $statusColor = "red" }
        "Offline"  { $statusColor = "red" }
        "READ_ONLY" { $statusColor = "yellow" }
        "OFFLINE"  { $statusColor = "red" }
        "Stopped"  { $statusColor = "red" }
        "Warning"  { $statusColor = "yellow" }
        "Good"     { $statusColor = "green" }
        "Running"  { $statusColor = "lightgreen" }
        "Online"   { $statusColor = "lightgreen" }
        
                            }
    $html += "<tr>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td>$($row.name)</td>"
    $html += "<td style='background-color: $statusColor;'>$($row.state_desc)</td>"
    #$html += "<td>$($row.Status)</td>"    
    $html += "</tr>"
}

$html += @"
    </table>
    <h2 style="color: #DF9229;">Always On Availability Groups Status</h2>
    <table>
        <tr>
            <th>HA Type</th>
            <th>AG/Database Name</th>
            <th>Server Name</th>
            <th>Replica Role</th>
            <th>Availability Mode</th>
            <th>Failover Mode</th>
            <th>Connection State</th>
            <th>Sync Health</th>
            <th>Sync State</th>
            <th>Is Suspended</th>
        </tr>
"@

foreach ($row in $AlwaysOn) {
    # Determine base row highlight based on sync health
    $statusColor = "white"
    
    switch ($row.synchronization_health_desc) {
        "HEALTHY" { $statusColor = "lightgreen" }
        "PARTIALLY_HEALTHY" { $statusColor = "yellow" }
        "NOT_HEALTHY" { $statusColor = "red" }
    }

    # Override for disconnected
    if ($row.connected_state_desc -eq "DISCONNECTED") {
        $statusColor = "red"
    }

    # Override for suspended
    if ($row.is_suspended -eq 1) {
        $statusColor = "orange"
    }

    $html += "<tr>"
    $html += "<td>$($row.HA_Type)</td>"

    # Display AG or Database name
    $displayName = if ($row.AG_Name) { $row.AG_Name } elseif ($row.Database_Name) { $row.Database_Name } else { "N/A" }
    $html += "<td>$displayName</td>"

    $html += "<td>$($row.Server_Name)</td>"

    # Add Replica Role with highlight (optional)
    $roleColor = if ($row.role_desc -eq "PRIMARY") { "lightblue" } elseif ($row.role_desc -eq "SECONDARY") { "lightgray" } else { "white" }
    $html += "<td style='background-color: $roleColor; text-align: center;'>$($row.role_desc)</td>"

    $html += "<td style='text-align: center;'>$($row.availability_mode_desc)</td>"
    $html += "<td style='text-align: center;'>$($row.failover_mode_desc)</td>"
    $html += "<td style='text-align: center;'>$($row.connected_state_desc)</td>"
    $html += "<td style='background-color: $statusColor; text-align: center;'>$($row.synchronization_health_desc)</td>"
    $html += "<td style='text-align: center;'>$($row.synchronization_state_desc)</td>"

    # Suspended state
    $suspendedText = if ($row.is_suspended -eq 1) { "Yes" } else { "No" }
    $suspendedColor = if ($row.is_suspended -eq 1) { "orange" } else { "white" }
    $html += "<td style='background-color: $suspendedColor; text-align: center;'>$suspendedText</td>"

    $html += "</tr>"
}


# HTML GENERATION FOR DATABASE MIRRORING
$html += @"
    </table>
    <h2 style="color: #DF9229;">Database Mirroring Status</h2>
    <table>
        <tr>
            <th>HA Type</th>
            <th>Database Name</th>
            <th>Server Name</th>
            <th>State</th>
            <th>Role</th>
            <th>Partner Name</th>
            <th>Witness Name</th>
            <th>Witness State</th>
            <th>Safety Level</th>
            <th>Status</th>
        </tr>
"@

foreach ($row in $mirroring) {
    # Color coding for mirroring state
    $statusColor = ""
    switch ($row.mirroring_state_desc) {
        "SYNCHRONIZED" { $statusColor = "lightgreen" }
        "SYNCHRONIZING" { $statusColor = "yellow" }
        "DISCONNECTED" { $statusColor = "red" }
        "SUSPENDED" { $statusColor = "orange" }
        default { $statusColor = "white" }
    }
    
    $html += "<tr>"
    $html += "<td>$($row.HA_Type)</td>"
    $html += "<td>$($row.database_name)</td>"
    $html += "<td>@@SERVERNAME</td>"  # Since this runs locally
    $html += "<td style='background-color: $statusColor; text-align: center;'>$($row.mirroring_state_desc)</td>"
    $html += "<td style='text-align: center;'>$($row.mirroring_role_desc)</td>"
    $html += "<td>$($row.mirroring_partner_name)</td>"
    $html += "<td>$($row.mirroring_witness_name)</td>"
    $html += "<td style='text-align: center;'>$($row.mirroring_witness_state_desc)</td>"
    $html += "<td style='text-align: center;'>$($row.mirroring_safety_level_desc)</td>"
    $html += "<td style='background-color: $statusColor; text-align: center;'>$($row.mirroring_state_desc)</td>"
    $html += "</tr>"
}

# HTML GENERATION FOR LOG SHIPPING
$html += @"
    </table>
    <h2 style="color: #DF9229;">Log Shipping Status</h2>
    <table>
        <tr>
            <th>HA Type</th>
            <th>Database Name</th>
            <th>Server Name</th>
            <th>Role</th>
        </tr>
"@

foreach ($row in $Logshipping) {
    # Color coding based on threshold and alert status
    $statusColor = "lightgreen"  # Default to good
    
    # You can add logic here to check if backup/restore is within threshold
    if ($row.threshold_alert_enabled -eq 1) {
        $statusColor = "yellow"  # Alerts are enabled, might need attention
    }
    
    $html += "<tr>"
    $html += "<td>$($row.HA_Type)</td>"
    $html += "<td>$($row.Database_Name)</td>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td>$($row.Role)</td>"
    
    # Handle different job name fields
    $jobName = ""
    if ($row.backup_job_name) { $jobName = $row.backup_job_name }
    elseif ($row.restore_job_name) { $jobName = $row.restore_job_name }
    else { $jobName = "N/A" }
    
    $html += "<td>$jobName</td>"
    $html += "<td>$($row.monitor_server)</td>"
    
    # Handle different date fields
    $lastDate = ""
    if ($row.last_backup_date) { $lastDate = $row.last_backup_date }
    elseif ($row.last_restored_date) { $lastDate = $row.last_restored_date }
    else { $lastDate = "N/A" }
    
    $html += "<td>$lastDate</td>"
    
    # Handle different file fields
    $lastFile = ""
    if ($row.last_backup_file) { $lastFile = $row.last_backup_file }
    elseif ($row.last_restored_file) { $lastFile = $row.last_restored_file }
    else { $lastFile = "N/A" }
    
    $html += "<td>$lastFile</td>"
    
    # Handle different threshold fields
    $threshold = ""
    if ($row.backup_threshold) { $threshold = $row.backup_threshold }
    elseif ($row.restore_threshold) { $threshold = $row.restore_threshold }
    else { $threshold = "N/A" }
    
    $html += "<td style='text-align: center;'>$threshold</td>"
    $html += "<td style='text-align: center;'>$($row.threshold_alert_enabled)</td>"
    $html += "<td style='background-color: $statusColor; text-align: center;'>Active</td>"
    $html += "</tr>"
}

# HTML GENERATION FOR REPLICATION
$html += @"
    </table>
    <h2 style="color: #DF9229;">SQL Server Replication Status</h2>
    <table>
        <tr>
            <th>HA Type</th>
            <th>Database Name</th>
            <th>Server Name</th>
            <th>Replication Role</th>
            <th>Status</th>
        </tr>
"@

foreach ($row in $Replication) {
    # Color coding based on replication role
    $roleColor = switch ($row.Replication_Role) {
        "Publisher"   { "lightblue" }
        "Subscriber"  { "lightcyan" }
        "Distributor" { "lightsteelblue" }
        default       { "white" }
    }

    $html += "<tr>"
    $html += "<td>$($row.HA_Type)</td>"
    $html += "<td>$($row.Database_Name)</td>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td style='background-color: $roleColor; text-align: center;'>$($row.Replication_Role)</td>"
    $html += "<td style='background-color: $roleColor; text-align: center;'>$($row.Status)</td>"
    $html += "</tr>"
}



# CPU table
$html += @"
    </table>
    <h2 style="color: #DF9229;">CPU Utilization Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Number of physical CPUs</th>
            <th>Number of cores per CPU</th>
            <th>Total number of cores</th>
            <th>Number of virtual CPUs</th>
            <th>CPU category</th>
            <th>SQL Server CPU (%)</th>
            <th>Other Process CPU (%)</th>
            <th>Total CPU Usage (%)</th>
            <th>Status</th>
        </tr>
"@

foreach ($row in $cpudata) {
    switch ($row.Status) {
        "Total CPU Usage is Very High" { $statusColor = "red" }
        "Total CPU Usage is High" { $statusColor = "orange" }
        "CPU Utilisation looks Good" { $statusColor = "lightgreen" }
        "Warning" { $statusColor = "yellow" }
        "Good" { $statusColor = "green" }
        "HEALTHY" { $statusColor = "lightgreen" }
        " " { $statusColor = "white" }
        default { $statusColor = "white" }
    }

    $html += "<tr>"
    $html += "<td>$($row.servername)</td>"
    $html += "<td>$($row.number_of_physical_cpus)</td>"
    $html += "<td>$($row.number_of_cores_per_cpu)</td>"
    $html += "<td style='text-align: right;'>$($row.total_number_of_cores)</td>"
    $html += "<td style='text-align: right;'>$($row.number_of_virtual_cpus)</td>"
    $html += "<td style='text-align: right;'>$($row.cpu_category)</td>"
    $html += "<td style='text-align: right;'>$($row.SQLServerCPU)</td>"
    $html += "<td style='text-align: right;'>$($row.OtherProcessCPU)</td>"
    $html += "<td style='text-align: right;'>$($row.TotalCPUUsage)</td>"
    $html += "<td style='background-color: $statusColor; text-align: left;'>$($row.Status)</td>"
    $html += "</tr>"
}

#servername	number_of_physical_cpus	number_of_cores_per_cpu	total_number_of_cores	number_of_virtual_cpus	cpu_category	AVG_Utilization	Status

#MEMORY table
$html += @"
    </table>
    <h2 style="color: #DF9229;">MEMORY Utilization Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Page Life Expectancy</th>
            <th>Memory Grants Pending</th>
            <th>Min Server Memory (GB)</th>
            <th>Max Server Memory (GB)</th>
            <th>Total Server Memory (GB)</th>
            <th>Target Server Memory (GB)</th>
            <th>System Physical Memory (GB)</th>
            <th>Total Memory Used (MB)</th>
            <th>Buffer Pool Allocated (MB)</th>
            <th>Comments</th>
        </tr>
"@

foreach ($row in $memdata) {
    switch ($row.Comments) {
        "Memory Utilisation is HIGH" { $statusColor = "red" }
        "Memory Utilisation looks GOOD" { $statusColor = "lightgreen" }
        default { $statusColor = "white" }
    }

    $html += "<tr>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td style='text-align: right;'>$($row.PageLifeExpectancy)</td>"
    $html += "<td style='text-align: right;'>$($row.MemoryGrantsPending)</td>"
    $html += "<td style='text-align: right;'>$($row.MinServerMemory_GB)</td>"
    $html += "<td style='text-align: right;'>$($row.MaxServerMemory_GB)</td>"
    $html += "<td style='text-align: right;'>$($row.TotalServerMemory_GB)</td>"
    $html += "<td style='text-align: right;'>$($row.TargetServerMemory_GB)</td>"
    $html += "<td style='text-align: right;'>$($row.SystemPhysicalMemory_GB)</td>"
    $html += "<td style='text-align: right;'>$($row.TotalMemoryUsed_MB)</td>"
    $html += "<td style='text-align: right;'>$($row.BufferPoolAllocated_MB)</td>"
    $html += "<td style='background-color: $statusColor;'>$($row.Comments)</td>"
    $html += "</tr>"
}

									




#Deadlock Table
$html += @"
    </table>
    <h2 style="color: #DF9229;">Blocking/Deadlock Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>HostName</th>
            <th>Blocking</th>
            <th>DbName</th>
            <th>LoginName</th>
            <th>LeadingBlocker</th>
            <th>WaitingSpid</th>
            <th>Command</th>
            <th>LoginTime</th>
            <th>LastRequestStart</th>
            <th>LastRequestEnd</th>
            <th>BlockingChain</th>
            <th>leading statement</th>
            <th>waiting query</th>
            <th>SessionInfo</th>  
        </tr>
"@

foreach ($row in $deadlockdata) {
switch ($row.Blocking) {
        "Blocking Detected"     { $statusColor = "red" }
        "No Blocking Detected"  { $statusColor = "lightgreen" }
                       }
    $html += "<tr>"
    $html += "<td>$($row.servername)</td>"    
    $html += "<td>$($row.HostName)</td>"
    $html += "<td style='background-color: $statusColor;'>$($row.Blocking)</td>"
    $html += "<td style='text-align: right;'>$($row.DbName)</td>"
    $html += "<td style='text-align: right;'>$($row.LoginName)</td>"
    $html += "<td style='text-align: right;'>$($row.LeadingBlocker)</td>"
    $html += "<td style='text-align: right;'>$($row.WaitingSpid)</td>"
    $html += "<td style='text-align: right;'>$($row.Command)</td>"
    $html += "<td style='text-align: right;'>$($row.LoginTime)</td>"
    $html += "<td style='text-align: right;'>$($row.LastRequestStart)</td>"
    $html += "<td style='text-align: right;'>$($row.LastRequestEnd)</td>"
    $html += "<td style='text-align: right;'>$($row.BlockingChain)</td>"
    $html += "<td style='text-align: right;'>$($row.leading_statement)</td>"
    $html += "<td style='text-align: right;'>$($row.waiting_query)</td>"
    $html += "<td style='text-align: right;'>$($row.SessionInfo)</td>"          
    $html += "</tr>"
}

#Disk Table
$html += @"
    </table>
    <h2 style="color: #DF9229;">Disk Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Disk</th>
            <th>Total Size GB</th>
            <th>Available Size GB</th>
            <th>SpaceFree</th>
            <th>Status</th>                      					
        </tr>
"@

foreach ($row in $diskdata) {
switch ($row.Status) {
        "Critical" { $statusColor = "red" }
        "Offline" { $statusColor = "red" }
        "Stopped" { $statusColor = "red" }
        "Warning" { $statusColor = "yellow" }
        "Good" { $statusColor = "green" }
        "Healthy" { $statusColor = "lightgreen" }
        "Online" { $statusColor = "lightgreen" }
    }
    $html += "<tr>"
    $html += "<td>$($row.server_name)</td>"
    $html += "<td>$($row.DiskMountPoint)</td>"
    $html += "<td style='text-align: right;'>$($row.TotalSizeGB)</td>"
    $html += "<td style='text-align: right;'>$($row.AvailableSizeGB)</td>"
    $html += "<td style='text-align: right;'>$($row.SpaceFree)</td>"
    $html += "<td style='background-color: $statusColor; text-align: center;'>$($row.Status)</td>"
    #$html += "<td style='background-color: $($row.statusColor); text-align: center;'>$($row.Status)</td>"
    #$html += "<td style='background-color: $statusColor;'>$($row.Status)</td>" 
    $html += "</tr>"
}

#Temp Data
$html += @"
</table>
<body>
    <h2 style="color: #DF9229;">TempDB Utilisation Status</h2>
    <table>
        <tr>
            <th>Server</th>
            <th>Database Name</th>
            <th>FilesizeMB</th>
            <th>Available SpaceMB</th>
            <th>Percentfull</th>
            <th>status</th>
            
        </tr>
"@

foreach ($row in $tempdata) {
switch ($row.Status) {
        "Tempdb Running OUTOF Threshold" { $statusColor = "red" }
        "Tempdb Running Within Threshold" { $statusColor = "lightgreen" }
        
    }
    $html += "<tr>"
    $html += "<td>$($row.servername)</td>"
    $html += "<td style='text-align: center;'>$($row.databasename)</td>"
    $html += "<td style='text-align: right;'>$($row.filesizeMB)</td>"
    $html += "<td style='text-align: right;'>$($row.availableSpaceMB)</td>"
    $html += "<td style='text-align: center;'>$($row.percentfull)</td>"
    $html += "<td style='background-color: $statusColor; text-align: center;'>$($row.status)</td>"    
    $html += "</tr>"
}

#Newly Created Jobs
$html += @"
    </table>
    <h2 style="color: #DF9229;">SQL Server New Job Creation Report</h2>
    <table>
        <tr>
            <th>job_name</th>
            <th>date_created</th>
            <th>job_status</th>
            <th>last_run_status</th>
            <th>last_run_date</th>
            <th>last_run_duration_in_minutes</th>
            <th>schedule_name</th>
            <th>schedule_enabled</th>                     					
        </tr>
"@
#job_name	date_created	job_status	last_run_status	last_run_date	last_run_duration_in_minutes	schedule_name	schedule_enabled
foreach ($row in $NewlyCretedJobs) {
switch ($row.LastRunOutcome) {
        "Critical" { $statusColor = "red" }
        "Failed"   { $statusColor = "red" }
        "Stopped"  { $statusColor = "red" }
        "Warning"  { $statusColor = "yellow" }
        "Good"     { $statusColor = "green" }
        "Running"  { $statusColor = "lightgreen" }
        "Online"   { $statusColor = "lightgreen" }
                     }
    $html += "<tr>"
    $html += "<td>$($row.job_name)</td>"
    $html += "<td>$($row.date_created)</td>"
    $html += "<td>$($row.job_status)</td>"
    $html += "<td>$($row.last_run_status)</td>"
    $html += "<td>$($row.last_run_date)</td>"
    $html += "<td>$($row.last_run_duration_in_minutes)</td>"
    $html += "<td>$($row.schedule_name)</td>"
    $html += "<td>$($row.schedule_enabled)</td>"
    #$html += "<td>$($row.NextRunTime)</td>"
    #$html += "<td style='background-color: $statusColor; text-align: center;'>$($row.LastRunOutcome)</td>"
    $html += "</tr>"
}

#JOB information
$html += @"
    </table>
    <h2 style="color: #DF9229;">SQL Server Job Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>JobName</th>
            <th>JobOwner</th>
            <th>Schedule Name</th>
            <th>IsEnabled</th>
            <th>Frequency</th>
            <th>Interval</th>
            <th>Time</th>
            <th>NextRun Time</th>
            <th>LastRun Status</th>                      					
        </tr>
"@

foreach ($row in $job) {
switch ($row.LastRunOutcome) {
        "Critical" { $statusColor = "red" }
        "Failed"   { $statusColor = "red" }
        "Stopped"  { $statusColor = "red" }
        "Warning"  { $statusColor = "yellow" }
        "Good"     { $statusColor = "green" }
        "Running"  { $statusColor = "lightgreen" }
        "Online"   { $statusColor = "lightgreen" }
                     }
    $html += "<tr>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td>$($row.JobName)</td>"
    $html += "<td>$($row.JobOwner)</td>"
    $html += "<td>$($row.ScheduleName)</td>"
    $html += "<td>$($row.IsEnabled)</td>"
    $html += "<td>$($row.Frequency)</td>"
    $html += "<td>$($row.Interval)</td>"
    $html += "<td>$($row.Time)</td>"
    $html += "<td>$($row.NextRunTime)</td>"
    $html += "<td style='background-color: $statusColor; text-align: center;'>$($row.LastRunOutcome)</td>"
    #$html += "<td>$($row.Status)</td>"    
    $html += "</tr>"
}			


#SYSADMIN Account list
$html += @"
    </table>
    <h2 style="color: #DF9229;">List of SYSADMIN accounts</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Login Name</th>
            <th>Type</th>
            <th>SQL/Windows Login</th>
            <th>Created Date</th>
            <th>Update Date</th>
                  
        </tr>
"@
					
foreach ($row in $sysadmin) {
    $html += "<tr>"
    $html += "<td>$($row.Server_Name)</td>"
    $html += "<td>$($row.loginname)</td>"
    $html += "<td>$($row.type)</td>"
    $html += "<td>$($row.type_desc)</td>"
    $html += "<td>$($row.created)</td>"
    $html += "<td>$($row.update)</td>"          
    $html += "</tr>"
}

#Linkedserver Table
$html += @"
    </table>
    <h2 style="color: #DF9229;">Linkedserver Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>server id</th>
            <th>Name</th>
            <th>Product</th>
            <th>Provider</th>
            <th>data_source</th>
            <th>Location</th>
            <th>Provider string</th>
        </tr>
"@

foreach ($row in $linkedserverData) {
    $html += "<tr>"
    $html += "<td>$($row.servername)</td>"
    $html += "<td>$($row.server_id)</td>"
    $html += "<td>$($row.name)</td>"
    $html += "<td>$($row.product)</td>"
    $html += "<td>$($row.provider)</td>"
    $html += "<td>$($row.data_source)</td>"
    $html += "<td>$($row.location)</td>"
    $html += "<td>$($row.provider_string)</td>"
    $html += "</tr>"
}

#Backup table
$html += @"
    </table>
    <h2 style="color: #DF9229;">Backup Report</h2>
    <table>
        <tr>
            <th>Server Name</th>
            <th>Database Name</th>
            <th>RecoveryModel</th>
            <th>DBStatus</th>
            <th>DB Mode</th>
            <th>LastFullBackup</th>
            <th>LastDiffBackup</th>
            <th>LastLogBackup</th>
        </tr>
"@

foreach ($row in $backupData) {
    # Color coding for DB Mode
    $dbModeColor = ""
    switch ($row.DBMode) {
        "SINGLE_USER" { $dbModeColor = "orange" }
        "RESTRICTED_USER" { $dbModeColor = "yellow" }
        "MULTI_USER" { $dbModeColor = "lightgreen" }
        default { $dbModeColor = "white" }
    }
    
    $html += "<tr>"
    $html += "<td>$($row.Server_name)</td>"
    $html += "<td>$($row.DBName)</td>"
    $html += "<td>$($row.RecoveryModel)</td>"
    $html += "<td>$($row.DBStatus)</td>"
    $html += "<td style='background-color: $dbModeColor; text-align: center;'>$($row.DBMode)</td>"
    $html += "<td>$($row.LastFullBackup)</td>"
    $html += "<td>$($row.LastDiffBackup)</td>"
    $html += "<td>$($row.LastLogBackup)</td>"
    $html += "</tr>"
}


$html += @"
</table>
</body>
</html>
"@

# Save HTML to file
$outputFile = "C:\Healthcheck-report\Database_Healthcheck_Report.html"
$html | Out-File -FilePath $outputFile -Encoding UTF8
