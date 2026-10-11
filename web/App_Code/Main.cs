// v3 compatibility layer for existing IIS Reports analytic endpoints.
using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using IISReports.V3;
namespace IISReports
{
    public static class Config
    {
        public static string ConnStr { get { return Settings.ConnectionString; } }
        public static string AppRoot { get { return HttpRuntime.AppDomainAppPath; } }
    }
    public static class Db
    {
        public static SqlConnection Open(){return Store.Open();}
        public static void EnsureSchema(){using(var c=Open())Store.CheckSchema(c);}
        public static long CountEntries(){using(var c=Open())return Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.CurrentRequests"));}
    }
    public class LogService
    {
        public class QueryFilters
        {
            public int? SiteId;
            public string ClientIp;
            public string UserName;
            public int? Status;
            public List<int> StatusCategories; // 2,3,4,5
            public string Method;
            public string TargetEq;
            public string Search;
            public DateTime? From;
            public DateTime? To;

            public void Apply(SqlCommand cmd)
            {
                var where = new List<string>();
                if (SiteId.HasValue && SiteId.Value > 0)
                {
                    where.Add("SiteId=@sid"); cmd.Parameters.AddWithValue("@sid", SiteId.Value);
                }
                if (!string.IsNullOrEmpty(ClientIp))
                {
                    where.Add("ClientIp LIKE @cip"); cmd.Parameters.AddWithValue("@cip", "%" + ClientIp + "%");
                }
                if (!string.IsNullOrEmpty(UserName))
                {
                    where.Add("UserName LIKE @usr"); cmd.Parameters.AddWithValue("@usr", "%" + UserName + "%");
                }
                if (Status.HasValue)
                {
                    where.Add("Status=@st"); cmd.Parameters.AddWithValue("@st", Status.Value);
                }
                if (StatusCategories != null && StatusCategories.Count > 0)
                {
                    var ors = new List<string>();
                    foreach (var cat in StatusCategories)
                    {
                        ors.Add("(Status >= " + (cat * 100) + " AND Status < " + ((cat + 1) * 100) + ")");
                    }
                    where.Add("(" + string.Join(" OR ", ors) + ")");
                }
                if (!string.IsNullOrEmpty(Method))
                {
                    where.Add("Method=@m"); cmd.Parameters.AddWithValue("@m", Method);
                }
                if (!string.IsNullOrEmpty(TargetEq))
                {
                    where.Add("(CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END)=@t");
                    cmd.Parameters.AddWithValue("@t", TargetEq);
                }
                if (!string.IsNullOrEmpty(Search))
                {
                    where.Add(@"(UriStem LIKE @s OR UriQuery LIKE @s OR UserAgent LIKE @s OR Referer LIKE @s)");
                    cmd.Parameters.AddWithValue("@s", "%" + Search + "%");
                }
                if (From.HasValue)
                {
                    where.Add("Ts >= @from"); cmd.Parameters.Add("@from",SqlDbType.DateTime2).Value=From.Value;
                }
                if (To.HasValue)
                {
                    where.Add("Ts < @to"); cmd.Parameters.Add("@to",SqlDbType.DateTime2).Value=To.Value;
                }
                cmd.CommandText += " WHERE 1=1" + (where.Count > 0 ? " AND " + string.Join(" AND ", where) : "");
            }

            public static QueryFilters FromRequest(HttpRequest req)
            {
                var f = new QueryFilters();

                int sid;
                if (int.TryParse(req["siteId"], out sid) && sid > 0) f.SiteId = sid;

                f.ClientIp = req["clientIp"];
                f.UserName = req["userName"];
                f.Method   = req["method"];
                f.TargetEq = req["targetEq"];
                f.Search   = req["search"];

                int st;
                if (int.TryParse(req["status"], out st)) f.Status = st;

                var sc = req["statusCategories"];
                if (!string.IsNullOrEmpty(sc))
                {
                    f.StatusCategories = new List<int>();
                    foreach (var s in sc.Split(','))
                    {
                        int v;
                        if (int.TryParse(s.Trim(), out v) && v >= 1 && v <= 5)
                            f.StatusCategories.Add(v);
                    }
                }

                DateTime d;
                if (DateTime.TryParse(req["from"], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d)) f.From = d.ToUniversalTime();
                if (DateTime.TryParse(req["to"], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d)) f.To   = d.ToUniversalTime();

                return f;
            }
        }
    }
    public static class GeoIp
    {
        private class Range
        {
            public uint Start;
            public uint End;
            public string Code = "";
        }

        private static Range[] _ranges = new Range[0];
        private static DateTime _lastWrite = DateTime.MinValue;
        private static DateTime _lastDbLoad = DateTime.MinValue;
        private static readonly object _lock = new object();

        public static void LoadIfChanged()
        {
            var secure = Path.Combine(Config.AppRoot, "App_Data", "geoip.csv");
            var path = File.Exists(secure) ? secure : Path.Combine(Config.AppRoot, "geoip.csv");
            DateTime lastWrite = DateTime.MinValue;
            try { if (File.Exists(path)) lastWrite = File.GetLastWriteTimeUtc(path); } catch { }

            lock (_lock)
            {
                if (lastWrite == _lastWrite && _ranges.Length > 0) return;

                var list = new List<Range>();
                try
                {
                    if (File.Exists(path))
                    {
                        foreach (var raw in File.ReadAllLines(path, Encoding.UTF8))
                        {
                            var line = raw.Trim();
                            if (line.Length == 0 || line[0] == '#') continue;
                            var p = line.Split(',');
                            if (p.Length < 3) continue;
                            uint s, e;
                            if (!uint.TryParse(p[0], out s)) continue;
                            if (!uint.TryParse(p[1], out e)) continue;
                            list.Add(new Range { Start = s, End = e, Code = p[2].Trim().Trim('"') });
                        }
                        list.Sort((a, b) => a.Start.CompareTo(b.Start));
                    }
                }
                catch { }

                _ranges = list.ToArray();
                _lastWrite = lastWrite;
            }
        }

        public static string CountryCode(string ip)
        {
            if (_ranges.Length == 0 || string.IsNullOrEmpty(ip) || ip == "-" || ip.Contains(":"))
                return null;

            var parts = ip.Split('.');
            if (parts.Length != 4) return null;
            uint u = 0;
            foreach (var p in parts)
            {
                byte b;
                if (!byte.TryParse(p, out b)) return null;
                u = (u << 8) | b;
            }

            var arr = _ranges;
            int lo = 0, hi = arr.Length - 1;
            while (lo <= hi)
            {
                int mid = (lo + hi) / 2;
                if (u < arr[mid].Start) hi = mid - 1;
                else if (u > arr[mid].End) lo = mid + 1;
                else return string.IsNullOrEmpty(arr[mid].Code) ? null : arr[mid].Code;
            }
            return null;
        }

        public static int RangeCount { get { return _ranges.Length; } }
        public static bool FileExists()
        {
            return File.Exists(Path.Combine(Config.AppRoot, "geoip.csv"));
        }
    }
    public static class SiteNames
    {
        private static Dictionary<int, string> _map = new Dictionary<int, string>();
        private static DateTime _lastWrite = DateTime.MinValue;
        private static DateTime _lastDbLoad = DateTime.MinValue;
        private static readonly object _lock = new object();

        public static void LoadIfChanged(bool force = false)
        {
            var path = Path.Combine(Config.AppRoot, "sites.json");
            DateTime lastWrite = DateTime.MinValue;
            try { if (File.Exists(path)) lastWrite = File.GetLastWriteTimeUtc(path); } catch { }

            lock (_lock)
            {
                if (!force && lastWrite == _lastWrite && _map.Count > 0 && (DateTime.UtcNow-_lastDbLoad).TotalSeconds<30) return;

                var dict = new Dictionary<int, string>();
                try
                {
                    using(var connection=IISReports.V3.Store.Open())
                    {
                        var names=IISReports.V3.Store.Rows(connection,null,"SELECT SiteId,Name FROM ir3.Sources ORDER BY Available ASC,Id ASC");
                        foreach(var row in names)dict[IISReports.V3.Store.Num(row["SiteId"])]=IISReports.V3.Store.Str(row["Name"]);
                    }
                    _lastDbLoad=DateTime.UtcNow;
                }
                catch { /* DB availability is reported separately by the API/health. */ }
                try
                {
                    if (File.Exists(path))
                    {
                        var json = File.ReadAllText(path, Encoding.UTF8);
                        var ser = new JavaScriptSerializer();
                        var obj = ser.Deserialize<Dictionary<string, string>>(json);
                        if (obj != null)
                            foreach (var kv in obj)
                            {
                                int sid;
                                if (int.TryParse(kv.Key, out sid) && !string.IsNullOrWhiteSpace(kv.Value))
                                    dict[sid] = kv.Value.Trim();
                            }
                    }
                }
                catch { }

                _map = dict;
                _lastWrite = lastWrite;
            }
        }

        public static string Get(int siteId)
        {
            string n;
            return _map.TryGetValue(siteId, out n) && !string.IsNullOrWhiteSpace(n)
                ? n : "W3SVC" + siteId;
        }

        public static Dictionary<int, string> All { get { return _map; } }
    }
}
