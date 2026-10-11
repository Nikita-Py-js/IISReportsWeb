using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web;
using System.Web.Script.Serialization;

namespace IISReports
{
    public static class AsnLookup
    {
        private sealed class Range { public uint Start, End; public string Asn, Name; }
        private static readonly object Gate = new object();
        private static Range[] _items = new Range[0];
        private static DateTime _mtime = DateTime.MinValue;
        private static long _size = -1;
        public static int Count { get { return _items.Length; } }
        public static void Reload()
        {
            string secure = Path.Combine(Config.AppRoot, "App_Data", "asn.csv");
            string path = File.Exists(secure) ? secure : Path.Combine(Config.AppRoot, "asn.csv");
            DateTime stamp = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;
            long len = File.Exists(path) ? new FileInfo(path).Length : 0;
            lock (Gate)
            {
                if (stamp == _mtime && len == _size) return;
                var list = new List<Range>();
                if (File.Exists(path))
                {
                    foreach (string line in File.ReadLines(path, Encoding.UTF8))
                    {
                        if (string.IsNullOrWhiteSpace(line) || line[0] == '#') continue;
                        var p = line.TrimStart('\uFEFF').Split(new [] { ',' }, 4);
                        uint start, end;
                        if (p.Length != 4 || !uint.TryParse(p[0], out start) ||
                            !uint.TryParse(p[1], out end) || end < start) continue;
                        list.Add(new Range { Start = start, End = end,
                            Asn = p[2].Trim(), Name = p[3].Trim().Trim('"') });
                    }
                }
                _items = list.OrderBy(x => x.Start).ToArray();
                _mtime = stamp; _size = len;
            }
        }
        private static bool IpNumber(string ip, out uint n)
        {
            n = 0;
            IPAddress value;
            if (!IPAddress.TryParse(ip, out value) || value.AddressFamily !=
                System.Net.Sockets.AddressFamily.InterNetwork) return false;
            byte[] b = value.GetAddressBytes();
            n = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
            return true;
        }
        public static object Info(string ip)
        {
            uint val;
            if (!IpNumber(ip, out val)) return new { asn = "", organization = "" };
            Range[] a = _items;
            int lo = 0, hi = a.Length - 1;
            while (lo <= hi)
            {
                int mid = lo + (hi - lo) / 2;
                if (val < a[mid].Start) hi = mid - 1;
                else if (val > a[mid].End) lo = mid + 1;
                else return new { asn = a[mid].Asn, organization = a[mid].Name };
            }
            return new { asn = "", organization = "" };
        }
    }
    public static class ExtraReports
    {
        private static int Site(HttpRequest req)
        { int site; return int.TryParse(req["siteId"], out site) && site > 0 ? site : 0; }
        private static SqlCommand Command(SqlConnection c, string sql, int site)
        {
            var cmd = c.CreateCommand();
            cmd.CommandTimeout = 90;
            cmd.CommandText = sql.Replace("/*SITE*/", site > 0 ? " AND SiteId=@sid" : "");
            if (site > 0) cmd.Parameters.Add("@sid", SqlDbType.Int).Value = site;
            return cmd;
        }
        private static int Num(SqlDataReader r, int i) { return r.IsDBNull(i) ? 0 : Convert.ToInt32(r.GetValue(i)); }
        private static long Big(SqlDataReader r, int i) { return r.IsDBNull(i) ? 0L : Convert.ToInt64(r.GetValue(i)); }
        private static string Str(SqlDataReader r, int i) { return r.IsDBNull(i) ? "" : r.GetValue(i).ToString(); }
        private static string Utc(SqlDataReader r, int i)
        { return r.IsDBNull(i) ? null : DateTime.SpecifyKind(r.GetDateTime(i), DateTimeKind.Utc).ToString("o", CultureInfo.InvariantCulture); }
        private static string TargetSql = "CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END";

        public static object Errors(HttpRequest req)
        {
            int site = Site(req);
            var codes = new List<object>(); var urls404 = new List<object>();
            var urls5xx = new List<object>(); var referers = new List<object>();
            using (var c = Db.Open())
            {
                using (var q = Command(c, @"SELECT TOP (60) Status,SubStatus,Win32Status,COUNT(*) AS N
                    FROM ir3.CurrentRequests WHERE Status BETWEEN 400 AND 599 /*SITE*/
                    GROUP BY Status,SubStatus,Win32Status ORDER BY N DESC", site))
                using (var r = q.ExecuteReader())
                    while (r.Read()) codes.Add(new { status = Num(r,0), subStatus = Num(r,1),
                        win32Status = Big(r,2), requests = Num(r,3) });
                using (var q = Command(c, @"SELECT TOP (35) " + TargetSql + @" AS Target,
                    COUNT(*) AS N,COUNT(DISTINCT ClientIp) AS Clients,MAX(Ts) AS LastSeen,
                    SUM(CASE WHEN UserAgent LIKE '%bot%' OR UserAgent LIKE '%scan%' OR UserAgent LIKE '%curl%' THEN 1 ELSE 0 END) AS SuspectedBots
                    FROM ir3.CurrentRequests WHERE Status=404 /*SITE*/
                    GROUP BY " + TargetSql + @" ORDER BY N DESC", site))
                using (var r = q.ExecuteReader())
                    while (r.Read()) urls404.Add(new { target = Str(r,0), requests = Num(r,1),
                        clients = Num(r,2), lastSeen = Utc(r,3), suspectedBotRequests = Num(r,4) });
                using (var q = Command(c, @"SELECT TOP (35) " + TargetSql + @" AS Target,
                    COUNT(*) AS N,COUNT(DISTINCT ClientIp) AS Clients,MAX(Ts) AS LastSeen,
                    AVG(CAST(TimeMs AS float)) AS AvgMs
                    FROM ir3.CurrentRequests WHERE Status BETWEEN 500 AND 599 /*SITE*/
                    GROUP BY " + TargetSql + @" ORDER BY N DESC", site))
                using (var r = q.ExecuteReader())
                    while (r.Read()) urls5xx.Add(new { target = Str(r,0), requests = Num(r,1),
                        clients = Num(r,2), lastSeen = Utc(r,3), avgMs = r.IsDBNull(4) ? 0 : Math.Round(r.GetDouble(4),1) });
                using (var q = Command(c, @"SELECT TOP (30) Referer,COUNT(*) AS N,
                    COUNT(DISTINCT UriStem) AS Targets FROM ir3.CurrentRequests
                    WHERE Status=404 AND Referer IS NOT NULL AND Referer<>'' AND Referer<>'-' /*SITE*/
                    GROUP BY Referer ORDER BY N DESC", site))
                using (var r = q.ExecuteReader())
                    while (r.Read()) referers.Add(new { referer = Str(r,0), requests = Num(r,1), targets = Num(r,2) });
            }
            return new { codes = codes, urls404 = urls404, urls5xx = urls5xx, referers404 = referers };
        }

        public static object Performance(HttpRequest req)
        {
            int hours;
            if (!int.TryParse(req["hours"], out hours) || (hours != 1 && hours != 24 && hours != 168)) hours = 24;
            int size = hours == 1 ? 1 : hours == 24 ? 5 : 60;
            var until = DateTime.UtcNow;
            var since = until.AddHours(-hours);
            int site = Site(req);
            var points = new List<object>();
            var bins = new Dictionary<int, object[]>();
            // P95 is the exact continuous percentile of individual requests per bucket.
            // RPS peak is the maximum count within any actual second, not a mean.
            string sql = @";WITH base AS (
 SELECT DATEDIFF(MINUTE,CONVERT(datetime2,'20000101'),Ts)/@bucket AS k,
        DATEDIFF(SECOND,@from,Ts) AS sec,
        Status, CAST(TimeMs AS float) AS duration
 FROM ir3.CurrentRequests WHERE Ts>=@from AND Ts<@to /*SITE*/
), valueset AS (
 SELECT k,sec,Status,duration,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration) OVER(PARTITION BY k) AS p95
 FROM base
), totals AS (
 SELECT k,COUNT_BIG(*) AS N, SUM(CASE WHEN Status BETWEEN 200 AND 299 THEN 1 ELSE 0 END) AS N2,
 SUM(CASE WHEN Status BETWEEN 400 AND 499 THEN 1 ELSE 0 END) AS N4,
 SUM(CASE WHEN Status BETWEEN 500 AND 599 THEN 1 ELSE 0 END) AS N5,
 AVG(duration) AS AvgMs, MAX(p95) AS P95Ms
 FROM valueset GROUP BY k
), peaks AS (
 SELECT k,MAX(n) AS PeakRps FROM (SELECT k,sec,COUNT(*) n FROM base GROUP BY k,sec) s GROUP BY k
)
SELECT t.k,t.N,t.N2,t.N4,t.N5,t.AvgMs,t.P95Ms,p.PeakRps
FROM totals t JOIN peaks p ON p.k=t.k ORDER BY t.k";
            using (var c = Db.Open())
            using (var q = Command(c, sql, site))
            {
                q.Parameters.Add("@from", SqlDbType.DateTime2).Value = since;
                q.Parameters.Add("@to", SqlDbType.DateTime2).Value = until;
                q.Parameters.Add("@bucket", SqlDbType.Int).Value = size;
                using (var r = q.ExecuteReader())
                    while (r.Read())
                    {
                        int k = Num(r, 0);
                        var t = new DateTime(2000,1,1,0,0,0,DateTimeKind.Utc).AddMinutes((long)k*size);
                        bins[k] = new object[] { Big(r,1),Big(r,2),Big(r,3),Big(r,4),
                            r.IsDBNull(5)?0.0:r.GetDouble(5),r.IsDBNull(6)?0.0:r.GetDouble(6),Num(r,7) };
                    }
            }
            var epoch=new DateTime(2000,1,1,0,0,0,DateTimeKind.Utc);
            int first=(int)Math.Floor((since-epoch).TotalMinutes/size);
            int last=(int)Math.Floor((until.AddTicks(-1)-epoch).TotalMinutes/size);
            for(int key=first;key<=last;key++)
            {
                object[] bin;bool found=bins.TryGetValue(key,out bin);
                long n=found?(long)bin[0]:0;
                DateTime time=epoch.AddMinutes((long)key*size),end=time.AddMinutes(size);
                double seconds=((end<until?end:until)-(time>since?time:since)).TotalSeconds;
                points.Add(new {ts=time.ToString("o",CultureInfo.InvariantCulture),requests=n,
                    status2xx=found?(long)bin[1]:0L,status4xx=found?(long)bin[2]:0L,status5xx=found?(long)bin[3]:0L,
                    avgMs=found?(double?)Math.Round((double)bin[4],1):null,
                    p95Ms=found?(double?)Math.Round((double)bin[5],1):null,peakRps=found?(int)bin[6]:0,
                    avgRps=seconds>0?Math.Round(n/seconds,3):0,rpm=seconds>0?Math.Round(60*n/seconds,2):0,
                    coveredSeconds=Math.Round(seconds,3)});
            }
            return new { hours = hours, bucketMinutes = size,
                from = since.ToString("o", CultureInfo.InvariantCulture),
                to = until.ToString("o", CultureInfo.InvariantCulture), points = points };
        }

        public static object Comparison(HttpRequest req)
        {
            int site = Site(req);
            int days;
            if (!int.TryParse(req["days"],out days) || (days != 1 && days != 7 && days != 30)) days=1;
            var end = DateTime.UtcNow;
            var middle = end.AddDays(-days);
            var start = middle.AddDays(-days);
            var data = new long[2,4];
            var duration = new double[2];
            var p95 = new double[2];
            string sql = @"SELECT CASE WHEN Ts<@mid THEN 0 ELSE 1 END AS Period,
 COUNT_BIG(*),SUM(CASE WHEN Status BETWEEN 400 AND 499 THEN CONVERT(bigint,1) ELSE 0 END),
 SUM(CASE WHEN Status BETWEEN 500 AND 599 THEN CONVERT(bigint,1) ELSE 0 END),
 AVG(CAST(TimeMs AS float)) FROM ir3.CurrentRequests
 WHERE Ts>=@start AND Ts<@end /*SITE*/ GROUP BY CASE WHEN Ts<@mid THEN 0 ELSE 1 END";
            using(var c=Db.Open()) using(var q=Command(c,sql,site))
            {
                q.Parameters.Add("@start",SqlDbType.DateTime2).Value=start;
                q.Parameters.Add("@mid",SqlDbType.DateTime2).Value=middle;
                q.Parameters.Add("@end",SqlDbType.DateTime2).Value=end;
                using(var r=q.ExecuteReader()) while(r.Read())
                {
                    int p=Num(r,0);
                    data[p,0]=Big(r,1);data[p,1]=Big(r,2);data[p,2]=Big(r,3);
                    duration[p]=r.IsDBNull(4)?0:r.GetDouble(4);
                }
            }
            // Separate percentile query avoids changing the GROUP BY semantics.
            using(var c=Db.Open())
            using(var q=Command(c,@"SELECT DISTINCT CASE WHEN Ts<@mid THEN 0 ELSE 1 END AS Period,
                PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CAST(TimeMs AS float))
                OVER(PARTITION BY CASE WHEN Ts<@mid THEN 0 ELSE 1 END) AS P95
                FROM ir3.CurrentRequests WHERE Ts>=@start AND Ts<@end /*SITE*/",site))
            {
                q.Parameters.Add("@start",SqlDbType.DateTime2).Value=start;
                q.Parameters.Add("@mid",SqlDbType.DateTime2).Value=middle;
                q.Parameters.Add("@end",SqlDbType.DateTime2).Value=end;
                using(var r=q.ExecuteReader()) while(r.Read()) p95[Num(r,0)]=r.IsDBNull(1)?0:r.GetDouble(1);
            }
            return new { previous = new { from=start.ToString("o",CultureInfo.InvariantCulture),to=middle.ToString("o",CultureInfo.InvariantCulture),
                requests=data[0,0],errors4xx=data[0,1],errors5xx=data[0,2],avgMs=Math.Round(duration[0],1),p95Ms=Math.Round(p95[0],1) },
                current = new { from=middle.ToString("o",CultureInfo.InvariantCulture),to=end.ToString("o",CultureInfo.InvariantCulture),
                requests=data[1,0],errors4xx=data[1,1],errors5xx=data[1,2],avgMs=Math.Round(duration[1],1),p95Ms=Math.Round(p95[1],1) } };
        }

        public static object Bots(HttpRequest req)
        {
            int site=Site(req);
            var list=new List<object>();
            string sql=@"SELECT TOP (60) ClientIp,COUNT(*) AS N,
 SUM(CASE WHEN Status BETWEEN 400 AND 499 THEN 1 ELSE 0 END) AS N4,
 SUM(CASE WHEN Status=401 OR Status=403 THEN 1 ELSE 0 END) AS Auth,
 MAX(UserAgent) AS UA,MAX(Ts) AS Seen,
 SUM(CASE WHEN LOWER(UserAgent) LIKE '%bot%' OR LOWER(UserAgent) LIKE '%spider%'
 OR LOWER(UserAgent) LIKE '%crawl%' OR LOWER(UserAgent) LIKE '%curl%'
 OR LOWER(UserAgent) LIKE '%python%' OR LOWER(UserAgent) LIKE '%scan%'
 OR LOWER(UserAgent) LIKE '%nmap%' OR LOWER(UserAgent) LIKE '%zgrab%' THEN 1 ELSE 0 END) AS UaFlag
 FROM ir3.CurrentRequests WHERE ClientIp IS NOT NULL /*SITE*/
 GROUP BY ClientIp HAVING COUNT(*)>=3
 ORDER BY N4 DESC,N DESC";
            using(var c=Db.Open()) using(var q=Command(c,sql,site))
            using(var r=q.ExecuteReader()) while(r.Read())
            {
                string ip=Str(r,0);long n=Big(r,1);int n4=Num(r,2),auth=Num(r,3),uaFlag=Num(r,6);
                string rating = (n4 >= 20 || auth >= 10 || uaFlag > 2) ? "suspect" : "review";
                list.Add(new { ip=ip,requests=n,errors4xx=n4,authFailures=auth,agent=Str(r,4),
                    lastSeen=Utc(r,5),suspected=rating,country=GeoIp.CountryCode(ip),asn=AsnLookup.Info(ip) });
            }
            return new { classification="heuristic-not-verified",rows=list,asnRanges=AsnLookup.Count };
        }
    }
}
