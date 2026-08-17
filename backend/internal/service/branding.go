package service

import "github.com/Wei-Shaw/sub2api/internal/branding"

// brandName 是 branding.Name() 在 service 包内的短别名。
//
// 存在的意义：service 包里有十几处「站点名称的兜底默认值」原本是硬编码的
// 品牌字面值。让它们统一走这个函数，tools/rebrand.sh 就只需要做纯文本
// 替换，不必给十几个文件插 import 语句 —— 那是 sed 最容易出错的地方。
//
// 这里刻意不导出：包外请直接用 branding.Name()。
func brandName() string { return branding.Name() }
