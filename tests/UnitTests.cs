using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Data;
using System.Data.SqlClient;
using IISReports;
using IISReports.V3;
public static class UnitTests
{
    private static int passed;
    private static void Check(bool ok,string name){if(!ok)throw new Exception(name);passed++;Console.WriteLine("PASS "+name);}
    private const string Header="#Fields: date time cs-method cs-uri-stem sc-status time-taken sc-win32-status\r\n";
    private const string Row="2026-10-11 18:00:00 GET /test 200 12 4294967295\r\n";
    private static ReadBatch Read(string text)
    {
        string file=Path.GetTempFileName();
        try{File.WriteAllText(file,text,new UTF8Encoding(false));using(var fs=File.OpenRead(file))return W3C.Read(fs,0,0,null,fs.Length);}
        finally{File.Delete(file);}
    }
    public static int Main()
    {
        try
        {
            var initial=Read(Header+Row+Row);
            Check(initial.Records.Count==2 && initial.Records[0].Error==null,"identical legitimate requests are separate");
            Check(initial.Records[0].Offset==Encoding.UTF8.GetByteCount(Header)&&initial.Records[1].Offset>initial.Records[0].Offset,"byte offsets");
            Check(initial.Records[0].Win32Status==4294967295L,"unsigned Win32 status fits bigint");
            Check(initial.Records[0].Timestamp.Kind==DateTimeKind.Utc,"UTC timestamp");
            Check(Read(Header+Row.TrimEnd('\r','\n')).Records.Count==0,"incomplete final line is not committed");
            var changed=Read(Header+Row+"#Fields: sc-status cs-uri-stem date time cs-method\n404 /x 2026-10-11 18:01:00 GET\n");
            Check(changed.Records.Count==2&&changed.Records[1].Status==404,"header field reordering");
            Check(Read("2026-10-11 18:00:00 GET /x 200\n").Records[0].Error!=null,"missing header quarantined");
            Check(Read(Header+"bad\n").Records[0].Error!=null,"wrong field count quarantined");
            Check(Read(Header+Row.Replace("200 12","200 -5")).Records[0].Error!=null,"negative timing quarantined");
            Check(Read(Header+Row.Replace("2026-10-11","2026-99-99")).Records[0].Error!=null,"bad date quarantined");
            var unicode=Read(Header+Row.Replace("/test","/\u0442\u0435\u0441\u0442"));
            Check(unicode.Records[0].UriStem=="/\u0442\u0435\u0441\u0442","UTF-8 path preserved");
            string temp=Path.GetTempFileName();
            try
            {
                var many=new StringBuilder(Header);for(int i=0;i<6000;i++)many.Append(Row);
                File.WriteAllText(temp,many.ToString(),new UTF8Encoding(false));
                using(var fs=File.OpenRead(temp))
                {
                    var first=W3C.Read(fs,0,0,null,fs.Length);
                    var next=W3C.Read(fs,first.End,first.LineNumber,first.Fields,fs.Length);
                    Check(first.Records.Count+next.Records.Count==6000&&next.End==fs.Length,"batch continuation retains header and offsets");
                    Check(Hashing.Equal(first.Hash,Hashing.Range(fs,first.Start,first.End)),"committed block checksum");
                }
            }
            finally{File.Delete(temp);}
            Check(Hashing.Equal(Hashing.Text("same"),Hashing.Text("same"))&&!Hashing.Equal(Hashing.Text("same"),Hashing.Text("changed")),"checksum equality");
            Check(AccessControl.SameOrigin("https://example.test/x","https://example.test"),"same origin accepts path in Referer");
            Check(!AccessControl.SameOrigin("https://example.test.evil/x","https://example.test"),"host suffix attack denied");
            Check(!AccessControl.SameOrigin("http://example.test/","https://example.test"),"scheme downgrade denied");
            Check(!AccessControl.SameOrigin("https://example.test:444","https://example.test"),"port mismatch denied");
            Check(!AccessControl.SameOrigin("https://user@example.test","https://example.test"),"userinfo denied");
            bool blocked=false;try{NetworkPolicy.Validate("https://unconfigured.invalid/",false);}catch(ArgumentException){blocked=true;}
            Check(blocked,"empty host allowlist denies network destinations");
            using(var c=new SqlConnection())using(var q=Store.Command(c,null,"SELECT @t","@t",DateTime.UtcNow))
                Check(q.Parameters[0].SqlDbType==SqlDbType.DateTime2&&q.Parameters[0].Scale==7,"SQL checkpoint time precision");
            Console.WriteLine("PASS TOTAL "+passed);return 0;
        }
        catch(Exception ex){Console.Error.WriteLine("FAIL "+ex);return 1;}
    }
}
