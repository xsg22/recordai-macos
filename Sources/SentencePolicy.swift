import Foundation

/// Shared Unicode terminal/abbreviation data; text boundaries are independent
/// of ASR transport windows and confidence in word timestamps.
enum SentencePolicy {
    struct Rules: Decodable {
        var terminals: String; var closers: String; var abbreviations: [String]
        var characterTarget: Int; var characterMaximum: Int; var wordTarget: Int; var wordMaximum: Int
    }
    static let rules: Rules = {
        if let url=Bundle.main.url(forResource:"SentenceRules",withExtension:"json"),let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode(Rules.self,from:data) { return value }
        return Rules(terminals:".!?。！？؟۔।॥",closers:"”’\"'」』）)]}»› \t\r\n",abbreviations:["mr","mrs","ms","dr","prof","sr","jr","st","vs","etc","e.g","i.e","a.m","p.m","no","fig","inc","ltd"],characterTarget:50,characterMaximum:75,wordTarget:30,wordMaximum:45)
    }()
    static func usesWords(_ text: String) -> Bool {
        text.range(of:"[\\u3400-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af\\u0e00-\\u0fff\\u1000-\\u109f\\u1780-\\u17ff]",options:.regularExpression)==nil
    }
    static func boundaries(_ chars: [Character]) -> Set<Int> {
        let terminals=Set(rules.terminals),closers=Set(rules.closers);var result=Set<Int>()
        for i in chars.indices where terminals.contains(chars[i]) {
            if chars[i]=="." {
                if i+1<chars.count && chars[i+1].isASCII && (chars[i+1].isLetter || chars[i+1].isNumber) { continue }
                var begin=i
                while begin>0 && (chars[begin-1].isLetter || chars[begin-1].isNumber || chars[begin-1]==".") { begin-=1 }
                let token=String(chars[begin..<i]).lowercased()
                var following=i+1
                while following<chars.count && closers.contains(chars[following]) { following+=1 }
                let initialism=token.range(of:"^(?:[\\p{L}]\\.)*[\\p{L}]$",options:.regularExpression) != nil && token.count<=7
                if following<chars.count && (rules.abbreviations.contains(token) || initialism) { continue }
            }
            var end=i+1
            while end<chars.count && (closers.contains(chars[end]) || terminals.contains(chars[end])) { end+=1 }
            result.insert(end)
        }
        return result
    }
    static func unitPrefix(_ chars:[Character], words:Bool) -> [Int] {
        var prefix=[0];var inside=false
        for c in chars {
            let letter=c.isLetter || c.isNumber
            let connector="'’-".contains(c)
            let add=words ? (letter && !inside) : letter
            prefix.append(prefix.last!+(add ? 1:0))
            inside=letter || (inside && connector)
        }
        return prefix
    }
}
