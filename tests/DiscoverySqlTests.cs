// Run ONLY on a newly initialized, EMPTY test database. Fixtures are retained, disabled.
using System;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using IISReports.V3;
public static class DiscoverySqlTests
{
    private static int passed;
    private static void Check(bool good,string name){if(!good)throw new Exception(name);passed++;Console.WriteLine("PASS "+name);}
    public static int Main()
    {
        string cs=Environment.GetEnvironmentVariable("IISREPORTS_TEST_CONNSTR");
        if(string.IsNullOrEmpty(cs)){Console.Error.WriteLine("Use Test-DiscoverySql.ps1 -EmptyTestDatabase ...");return 2;}
        var builder=new SqlConnectionStringBuilder(cs);builder.Pooling=false;
        bool fixtures=false;
        using(var c=new SqlConnection(builder.ConnectionString))
        {
            try
            {
                c.Open();Store.CheckSchema(c);
                int locked=Store.Num(Store.Scalar(c,null,"DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'IISReports.v3.agent',@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;SELECT @r;"));
                if(locked<0)throw new Exception("Agent owns this database. Stop it first.");
                if(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Sources"))!=0 || Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.Requests"))!=0)
                    throw new Exception("Refusing a nonempty database. Discovery tests require a NEW disposable database.");
                var snap=new InventorySnapshot{version=1,machineName=Environment.MachineName,generatedUtc=DateTime.UtcNow.ToString("o"),success=true,
                    sites=new[]{new InventorySite{siteId=41,name="Discovery test",rootPath=@"C:\IISReportsTest\W3SVC41",available=true,status="ready"}}};
                fixtures=true;SourceDiscovery.Apply(c,snap,DateTime.UtcNow);
                int first=Store.Num(Store.Scalar(c,null,"SELECT Id FROM ir3.Sources WHERE SiteId=41"));
                Check(SourceSelection.CanImport(c,null,first,false),"first discovered source is enabled");
                SourceSelection.Save(c,new[]{new SourceChange{id=first,revision=1,enabled=false}},"test");
                SourceDiscovery.Apply(c,snap,DateTime.UtcNow);
                Check(!SourceSelection.CanImport(c,null,first,false),"rediscovery never resets saved pause");
                Check(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Sources"))==1,"rediscovery does not duplicate source");
                Check(Store.Long(Store.Scalar(c,null,"SELECT Revision FROM ir3.Sources WHERE Id=@id","@id",first))==2,"discovery metadata does not change selection revision");
                snap.sites[0].rootPath=@"D:\MovedLogs\W3SVC41";SourceDiscovery.Apply(c,snap,DateTime.UtcNow);
                int moved=Store.Num(Store.Scalar(c,null,"SELECT TOP(1) Id FROM ir3.Sources WHERE SiteId=41 ORDER BY Id DESC"));
                Check(moved!=first&&!SourceSelection.CanImport(c,null,moved,false),"moved directory inherits previous pause");
                Check(Store.Str(Store.Scalar(c,null,"SELECT DiscoveryStatus FROM ir3.Sources WHERE Id=@id","@id",first))=="not_in_iis","former directory retained as inactive, not deleted");
                snap.sites=new[]{snap.sites[0],new InventorySite{siteId=42,name="New site",rootPath=@"C:\IISReportsTest\W3SVC42",available=false,status="waiting_directory"}};
                SourceDiscovery.Apply(c,snap,DateTime.UtcNow);
                int future=Store.Num(Store.Scalar(c,null,"SELECT Id FROM ir3.Sources WHERE SiteId=42"));
                Check(Store.Bool(Store.Scalar(c,null,"SELECT Enabled FROM ir3.Sources WHERE Id=@id","@id",future))&&!SourceSelection.CanImport(c,null,future,false),"future site selected but unavailable until directory appears");
                bool conflict=false;
                try{SourceSelection.Save(c,new[]{new SourceChange{id=moved,revision=1,enabled=true},new SourceChange{id=future,revision=999,enabled=false}},"test");}
                catch(SourceConflictException){conflict=true;}
                Check(conflict&&!Store.Bool(Store.Scalar(c,null,"SELECT Enabled FROM ir3.Sources WHERE Id=@id","@id",moved)),"bulk conflict rolls back all earlier updates");
                snap.sites[1].available=true;snap.sites[1].status="ready";SourceDiscovery.Apply(c,snap,DateTime.UtcNow);
                Check(SourceSelection.CanImport(c,null,future,false),"directory becomes available without manual registration");
                snap.sites=new InventorySite[0];SourceDiscovery.Apply(c,snap,DateTime.UtcNow);
                Check(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Sources"))==3,"removed sites retain source rows");
                Check(!SourceSelection.CanImport(c,null,future,false)&&Store.Bool(Store.Scalar(c,null,"SELECT Enabled FROM ir3.Sources WHERE Id=@id","@id",future)),"missing site keeps choice but is not imported");
                Console.WriteLine("PASS TOTAL "+passed+". Test fixtures retained and disabled.");return 0;
            }
            catch(Exception ex){Console.Error.WriteLine("FAIL "+ex.Message);return 1;}
            finally
            {
                if(fixtures&&c.State==ConnectionState.Open)
                    try{Store.Exec(c,null,"UPDATE ir3.Sources SET Enabled=0 WHERE Name IN('Discovery test','New site')");}catch{}
            }
        }
    }
}
