import Foundation
@main struct FeishuJSONSmoke {
 static func main() throws {
  let status: [String: Any] = ["appId":"app-a", "identities":["user":["available":true,"openId":"user-a","userName":"测试用户"]]]
  precondition(FeishuJSON.identity(status) == "app-a:user-a")
  precondition(FeishuJSON.identity(["appId":"app-a", "identity":"bot"]) == nil)
  let auth = try FeishuJSON.authorization(["verification_url":"https://accounts.feishu.cn/auth?code=example", "device_code":"example"])
  precondition(auth.url.host == "accounts.feishu.cn")
  precondition(FeishuJSON.officialURL("https://feishu.cn.evil.test/auth") == nil)
  precondition(FeishuJSON.officialURL("http://accounts.feishu.cn/auth") == nil)
  let result: [String:Any] = ["ok":true,"identity":"user","data":["document":["document_id":"doc-a","url":"https://example.feishu.cn/docx/doc-a"]]]
  let created = try FeishuJSON.createdDocument(result)
  precondition(created.id == "doc-a")
  precondition(FeishuJSON.fetchedContent(["ok":true,"identity":"user","data":["document":["content":"中文会议"]]]) == "中文会议")
  var bot = result; bot["identity"] = "bot"
  do { _ = try FeishuJSON.createdDocument(bot); fatalError("不能用机器人冒充个人") } catch { }
  print("Feishu JSON smoke passed（无登录和远程写入）")
 }
}
