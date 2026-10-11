// IIS Reports v3.0. Shared by the ASP.NET Web Site and the Windows agent.
// Language: C# 5. Runtime: .NET Framework 4.8. No NuGet packages.
using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace IISReports.V3
{
    public static class Settings
    {
        public static string Get(string name, string fallback)
        { string s = ConfigurationManager.AppSettings[name]; return s == null ? fallback : s.Trim(); }
        public static int Int(string name, int fallback, int min, int max)
        { int n; return int.TryParse(Get(name, ""), out n) ? Math.Max(min, Math.Min(max, n)) : fallback; }
        public static string ConnectionString
        {
            get { string s = Get("ConnStr", ""); if (s.Length == 0) throw new ConfigurationErrorsException("appSettings['ConnStr'] is not configured."); return s; }
        }
        public static string Json(object value)
        { return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(value); }
        public static string Clip(string value, int length)
        { return value == null ? "" : value.Length <= length ? value : value.Substring(0, length); }
        public static string Utc(DateTime value) { return DateTime.SpecifyKind(value, DateTimeKind.Utc).ToString("o", CultureInfo.InvariantCulture); }
    }

    public static class Store
    {
        public static SqlConnection Open()
        { var c = new SqlConnection(Settings.ConnectionString); try { c.Open(); return c; } catch { c.Dispose(); throw; } }
        public static SqlCommand Command(SqlConnection c, SqlTransaction tx, string sql, params object[] args)
        {
            if (args.Length % 2 != 0) throw new ArgumentException("Parameters must be name/value pairs.");
            var q = c.CreateCommand(); q.Transaction = tx; q.CommandText = sql; q.CommandTimeout = 90;
            for (int i = 0; i < args.Length; i += 2)
            {
                string name = (string)args[i]; object v = args[i + 1]; SqlParameter p;
                if (v is DateTime) { p = q.Parameters.Add(name, SqlDbType.DateTime2); p.Scale = 7; }
                else if (v is Guid) p = q.Parameters.Add(name, SqlDbType.UniqueIdentifier);
                else if (v is long) p = q.Parameters.Add(name, SqlDbType.BigInt);
                else if (v is int) p = q.Parameters.Add(name, SqlDbType.Int);
                else if (v is bool) p = q.Parameters.Add(name, SqlDbType.Bit);
                else if (v is double || v is float) p = q.Parameters.Add(name, SqlDbType.Float);
                else if (v is byte[]) p = q.Parameters.Add(name, SqlDbType.VarBinary, ((byte[])v).Length);
                else p = q.Parameters.Add(name, SqlDbType.NVarChar, v is string && ((string)v).Length > 4000 ? -1 : 4000);
                p.Value = v ?? DBNull.Value;
            }
            return q;
        }
        public static int Exec(SqlConnection c, SqlTransaction tx, string sql, params object[] args)
        { using (var q = Command(c, tx, sql, args)) return q.ExecuteNonQuery(); }
        public static object Scalar(SqlConnection c, SqlTransaction tx, string sql, params object[] args)
        { using (var q = Command(c, tx, sql, args)) { object v = q.ExecuteScalar(); return v == DBNull.Value ? null : v; } }
        public static List<Dictionary<string, object>> Rows(SqlConnection c, SqlTransaction tx, string sql, params object[] args)
        {
            var rows = new List<Dictionary<string, object>>();
            using (var q = Command(c, tx, sql, args)) using (var r = q.ExecuteReader())
                while (r.Read())
                {
                    var d = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 0; i < r.FieldCount; i++) d[r.GetName(i)] = r.IsDBNull(i) ? null : r.GetValue(i);
                    rows.Add(d);
                }
            return rows;
        }
        public static List<Dictionary<string, object>> Rows(string sql, params object[] args)
        { using (var c = Open()) return Rows(c, null, sql, args); }
        public static object Iso(object value)
        {
            var rows = value as IEnumerable<Dictionary<string, object>>;
            if (rows == null) return value;
            return rows.Select(r => r.ToDictionary(k => k.Key, k => k.Value is DateTime ? (object)Settings.Utc((DateTime)k.Value) : k.Value)).ToArray();
        }
        public static long Long(object o) { return o == null || o == DBNull.Value ? 0 : Convert.ToInt64(o, CultureInfo.InvariantCulture); }
        public static int Num(object o) { return checked((int)Long(o)); }
        public static string Str(object o) { return o == null || o == DBNull.Value ? "" : Convert.ToString(o, CultureInfo.InvariantCulture); }
        public static bool Bool(object o) { return o != null && o != DBNull.Value && Convert.ToBoolean(o); }
        public static void CheckSchema(SqlConnection c)
        {
            object version = Scalar(c, null, "IF OBJECT_ID('ir3.SchemaVersions','U') IS NOT NULL SELECT MAX(Version) FROM ir3.SchemaVersions;");
            if (Long(version) != 310) throw new InvalidOperationException("Run tools/Initialize-Database.ps1, including sql/005-auto-sources.sql (expected schema 310).");
        }
        public static DateTime? LastImport()
        {
            using (var c = Open())
            { object v = Scalar(c, null, "SELECT LastSuccessfulScanUtc FROM ir3.AgentState WHERE Id=1"); return v == null ? (DateTime?)null : DateTime.SpecifyKind((DateTime)v, DateTimeKind.Utc); }
        }
        public static void Audit(SqlConnection c, SqlTransaction tx, string actor, string action, string target, string detail)
        { Exec(c, tx, "INSERT ir3.AuditEvents(Actor,Action,Target,Detail) VALUES(@a,@k,@t,@d)", "@a", Settings.Clip(actor,256), "@k", action, "@t", Settings.Clip(target,160), "@d", Settings.Clip(detail,2048)); }
    }

    public static class Hashing
    {
        public static byte[] Bytes(byte[] value, int offset, int count)
        { using (var h = SHA256.Create()) return h.ComputeHash(value, offset, count); }
        public static byte[] Text(string value) { byte[] b = Encoding.UTF8.GetBytes(value); return Bytes(b,0,b.Length); }
        public static bool Equal(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int diff = 0; for (int i = 0; i < a.Length; i++) diff |= a[i] ^ b[i]; return diff == 0;
        }
        public static byte[] Range(FileStream file, long start, long end)
        {
            if (start < 0 || end < start || end > file.Length) throw new IOException("Checkpoint is outside the current file.");
            file.Position = start; long left = end - start; byte[] b = new byte[65536];
            using (var h = SHA256.Create())
            {
                while (left > 0)
                { int n = file.Read(b,0,(int)Math.Min(left,b.Length)); if (n == 0) throw new IOException("File changed while hashing."); h.TransformBlock(b,0,n,b,0); left -= n; }
                h.TransformFinalBlock(new byte[0],0,0); return h.Hash;
            }
        }
    }

    public sealed class ParsedRecord
    {
        public long Offset, End, LineNumber;
        public string Raw, Error;
        public byte[] Hash;
        public DateTime Timestamp;
        public string ServerIp, ClientIp, UserName, Method, UriStem, UriQuery, UserAgent, Referer;
        public int ServerPort, Status, SubStatus;
        public long Win32Status, TimeMs;
    }
    public sealed class ReadBatch
    {
        public long Start, End, LineNumber;
        public string Fields;
        public byte[] Hash;
        public List<ParsedRecord> Records = new List<ParsedRecord>();
    }
    public static class W3C
    {
        public const int ParserVersion = 300;
        public const int BatchBytes = 8 * 1024 * 1024;
        public const int MaxLineBytes = 1024 * 1024;
        private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
        public static ReadBatch Read(FileStream file, long position, long lineNumber, string fields, long snapshotLength)
        {
            if (position < 0 || position > snapshotLength || snapshotLength > file.Length) throw new IOException("Invalid checkpoint or truncated file.");
            var result = new ReadBatch { Start = position, End = position, LineNumber = lineNumber, Fields = fields };
            int want = (int)Math.Min(BatchBytes, snapshotLength-position);
            if (want == 0) return result;
            file.Position = position;
            var bytes = new byte[want]; int got = 0;
            while (got < want) { int n = file.Read(bytes,got,want-got); if (n==0) throw new IOException("File shortened during read."); got+=n; }
            int start = 0, lines = 0;
            for (int i=0;i<got;i++)
            {
                if (bytes[i] != 10)
                { if (i-start >= MaxLineBytes) throw new InvalidDataException("A log line exceeds 1 MiB. Import stopped; source and checkpoint preserved."); continue; }
                result.LineNumber++; lines++;
                int count = i-start; if (count>0 && bytes[i-1]==13) count--;
                string text; string decodeError = null;
                try { text=StrictUtf8.GetString(bytes,start,count); }
                catch (DecoderFallbackException) { text=Encoding.UTF8.GetString(bytes,start,count); decodeError="Invalid UTF-8"; }
                if(position+start==0) text=text.TrimStart('\uFEFF');
                if (text.StartsWith("#Fields:",StringComparison.OrdinalIgnoreCase)) result.Fields=text.Substring(8).Trim();
                else if (text.Length>0 && text[0]!='#')
                {
                    var row = new ParsedRecord { Offset=position+start, End=position+i+1, LineNumber=result.LineNumber,
                        Raw=text, Hash=Hashing.Bytes(bytes,start,i-start+1), Error=decodeError };
                    if (decodeError==null)
                    {
                        try { Parse(row,result.Fields); }
                        catch (FormatException ex) { row.Error=Settings.Clip(ex.Message,512); }
                    }
                    result.Records.Add(row);
                }
                result.End=position+i+1; start=i+1;
                if(lines>=5000) break;
            }
            if (result.End > position) result.Hash=Hashing.Bytes(bytes,0,checked((int)(result.End-position)));
            return result; // An unfinished final line is intentionally NOT committed.
        }
        private static string Value(Dictionary<string,string> d,string key,int max)
        {
            string s; if(!d.TryGetValue(key,out s)) s="-";
            if(s.Length>max) throw new FormatException(key+" exceeds "+max+" characters; raw text retained."); return s;
        }
        private static long Number(Dictionary<string,string> d,string key,long max)
        {
            string s=Value(d,key,32); if(s=="-")return 0;
            long n; if(!long.TryParse(s,NumberStyles.Integer,CultureInfo.InvariantCulture,out n)||n<0||n>max)
                throw new FormatException("Invalid numeric field: "+key); return n;
        }
        private static void Parse(ParsedRecord r,string fieldText)
        {
            if(string.IsNullOrWhiteSpace(fieldText)) throw new FormatException("No #Fields header before record.");
            var fields=fieldText.Split(new[]{' ','\t'},StringSplitOptions.RemoveEmptyEntries);
            var values=r.Raw.Split(new[]{' ','\t'},StringSplitOptions.RemoveEmptyEntries);
            if(fields.Length!=values.Length)throw new FormatException("Field count does not match #Fields.");
            var d=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            for(int i=0;i<fields.Length;i++) { if(d.ContainsKey(fields[i]))throw new FormatException("Duplicate field in #Fields."); d.Add(fields[i],values[i]); }
            DateTime ts;
            if(!DateTime.TryParseExact(Value(d,"date",10)+" "+Value(d,"time",16),
                new[]{"yyyy-MM-dd HH:mm:ss","yyyy-MM-dd HH:mm:ss.FFFFFFF"},CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal|DateTimeStyles.AdjustToUniversal,out ts)) throw new FormatException("Invalid UTC date/time.");
            r.Timestamp=ts; r.Method=Value(d,"cs-method",16); r.UriStem=Value(d,"cs-uri-stem",2048);
            r.UriQuery=Value(d,"cs-uri-query",2048); r.Status=(int)Number(d,"sc-status",999);
            if(r.Method=="-"||r.UriStem=="-"||r.Status<100)throw new FormatException("Required method, URI or status is missing.");
            r.ClientIp=Value(d,"c-ip",45);r.ServerIp=Value(d,"s-ip",45);r.UserName=Value(d,"cs-username",256);
            if(r.UserName=="-")r.UserName="Anonymous";
            r.ServerPort=(int)Number(d,"s-port",65535); r.SubStatus=(int)Number(d,"sc-substatus",int.MaxValue);
            r.Win32Status=Number(d,"sc-win32-status",uint.MaxValue); r.TimeMs=Number(d,"time-taken",long.MaxValue);
            r.UserAgent=Value(d,"cs(User-Agent)",1024);r.Referer=Value(d,"cs(Referer)",2048);
        }
    }
}
