# Apple's documented diagnostic fields only. Missing/contradictory required
# evidence fails before a log can be treated as release qualification.
def nullable_string: . == null or type == "string";
select(type == "object")
| select(.jobId | type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))
| select(.status == "Accepted" or .status == "Invalid" or .status == "Rejected")
| select(.statusSummary | nullable_string)
| select(.archiveFilename | nullable_string)
| select(.sha256 == null or (.sha256 | type == "string" and test("^[A-Fa-f0-9]{64}$")))
| select(.uploadDate | nullable_string)
| select(.logFormatVersion == null or (.logFormatVersion | type == "number"))
| select(.issues == null or (.issues | type == "array"))
| select(all(.issues[]?;
    type == "object"
    and (.severity == "error" or .severity == "warning")
    and (.message | type == "string")
    and (.code == null or (.code | type == "number" or type == "string"))
    and (.path | nullable_string)
    and (.docUrl | nullable_string)
    and (.architecture | nullable_string)))
| {jobId,status,statusSummary,archiveFilename,sha256,uploadDate,logFormatVersion,
   issues:(if .issues == null then null else [.issues[] | {severity,code,path,message,docUrl,architecture}] end)}
