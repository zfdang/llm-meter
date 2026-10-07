import Foundation

public enum AntigravityParsers {
  public static func status(_ data: Data, now: Date) throws -> UsageSnapshot {
    struct Reply: Decodable {
      struct User: Decodable {
        struct Plan: Decodable {
          struct Info: Decodable { let planName: String? }
          let planInfo: Info?
        }
        struct Config: Decodable {
          struct Model: Decodable {
            struct Quota: Decodable {
              let remainingFraction: Double?
              let resetTime: String?
            }
            struct Alias: Decodable {
              let model: String?
              let alias: String?
            }
            let modelId: String?
            let modelOrAlias: Alias?
            let label: String
            let quotaInfo: Quota?
          }
          let clientModelConfigs: [Model]?
        }
        let email: String
        let planStatus: Plan?
        let cascadeModelConfigData: Config?
      }
      let userStatus: User
    }
    guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
      !reply.userStatus.email.isEmpty
    else {
      throw MeterError.authentication("Sign in through the Antigravity app, then refresh.")
    }
    let user = reply.userStatus
    var metrics: [UsageMetric] = []
    for model in user.cascadeModelConfigData?.clientModelConfigs ?? [] {
      guard let quota = model.quotaInfo else { continue }
      let id =
        model.modelId ?? model.modelOrAlias?.model ?? model.modelOrAlias?.alias ?? model.label
      guard !metrics.contains(where: { $0.id == id }) else { continue }
      metrics.append(
        .init(
          id: id, name: model.label, scope: id,
          usedPercent: try used(quota.remainingFraction),
          resetAt: quota.resetTime.flatMap(UsageParsers.isoDate), readAt: now))
    }
    return .init(
      provider: .antigravity, accountID: SourceFiles.identifier(user.email.lowercased()),
      accountLabel: SourceFiles.masked(user.email), plan: user.planStatus?.planInfo?.planName,
      metrics: metrics, readAt: now, complete: false)
  }

  public static func summary(_ data: Data, now: Date) throws -> [UsageMetric] {
    struct Summary: Decodable {
      struct Group: Decodable {
        struct Bucket: Decodable {
          let bucketId: String?
          let window: String
          let remainingFraction: Double?
          let resetTime: String?
          let disabled: Bool?
        }
        let displayName: String
        let buckets: [Bucket]
      }
      let groups: [Group]
    }
    struct Envelope: Decodable { let response: Summary }
    let decoder = JSONDecoder()
    let summary: Summary
    if let envelope = try? decoder.decode(Envelope.self, from: data) {
      summary = envelope.response
    } else if let direct = try? decoder.decode(Summary.self, from: data) {
      summary = direct
    } else {
      throw MeterError.malformed("Unrecognized Antigravity quota summary.")
    }
    var metrics: [UsageMetric] = []
    for group in summary.groups where !group.displayName.isEmpty {
      let scope = "pool:\(group.displayName)"
      for bucket in group.buckets where bucket.disabled != true {
        let period: MetricPeriod =
          switch bucket.window.lowercased() {
          case "5h": .fiveHours
          case "weekly": .weekly
          default: .other
          }
        let id = "\(scope):\(bucket.bucketId ?? bucket.window)"
        guard !metrics.contains(where: { $0.id == id }) else { continue }
        metrics.append(
          .init(
            id: id, name: "\(group.displayName) · \(bucket.window)", period: period, scope: scope,
            usedPercent: try used(bucket.remainingFraction),
            resetAt: bucket.resetTime.flatMap(UsageParsers.isoDate), readAt: now))
      }
    }
    return metrics
  }

  private static func used(_ fraction: Double?) throws -> Double? {
    guard let fraction else { return nil }
    guard fraction.isFinite, (0...1).contains(fraction) else {
      throw MeterError.malformed("Invalid Antigravity quota fraction.")
    }
    return (1 - fraction) * 100
  }
}
