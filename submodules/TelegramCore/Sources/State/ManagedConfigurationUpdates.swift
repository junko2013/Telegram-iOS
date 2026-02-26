import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit


func managedConfigurationUpdates(accountManager: AccountManager<TelegramAccountManagerTypes>, postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = Signal<Void, NoError> { subscriber in
        return (combineLatest(
            network.request(Api.functions.help.getConfig()) |> retryRequest,
            network.request(Api.functions.messages.getDefaultHistoryTTL()) |> retryRequestIfNotFrozen
        )
        |> mapToSignal { result, defaultHistoryTtl -> Signal<Void, NoError> in
            return postbox.transaction { transaction -> Signal<Void, NoError> in
                switch result {
                case let .config(configData):
                    let (flags, chatSizeMax, megagroupSizeMax, forwardedCountMax, editTimeLimit, revokeTimeLimit, revokePmTimeLimit, stickersRecentLimit, autoupdateUrlPrefix, gifSearchUsername, venueSearchUsername, imgSearchUsername, webfileDcId, suggestedLangCode, langPackVersion, baseLangPackVersion, reactionsDefault, autologinToken) = (configData.flags, configData.chatSizeMax, configData.megagroupSizeMax, configData.forwardedCountMax, configData.editTimeLimit, configData.revokeTimeLimit, configData.revokePmTimeLimit, configData.stickersRecentLimit, configData.autoupdateUrlPrefix, configData.gifSearchUsername, configData.venueSearchUsername, configData.imgSearchUsername, configData.webfileDcId, configData.suggestedLangCode, configData.langPackVersion, configData.baseLangPackVersion, configData.reactionsDefault, configData.autologinToken)
                    
                    let blockedMode = (flags & (1 << 8)) != 0
                    
                    updateNetworkSettingsInteractively(transaction: transaction, network: network, { settings in
                        var settings = settings
                        settings.reducedBackupDiscoveryTimeout = blockedMode
                        settings.applicationUpdateUrlPrefix = autoupdateUrlPrefix
                        return settings
                    })
                    
                    updateRemoteStorageConfiguration(transaction: transaction, configuration: RemoteStorageConfiguration(webDocumentsHostDatacenterId: webfileDcId))
                    
                    transaction.updatePreferencesEntry(key: PreferencesKeys.suggestedLocalization, { entry in
                        var currentLanguageCode: String?
                        if let entry = entry?.get(SuggestedLocalizationEntry.self) {
                            currentLanguageCode = entry.languageCode
                        }
                        if currentLanguageCode != suggestedLangCode {
                            if let suggestedLangCode = suggestedLangCode {
                                return PreferencesEntry(SuggestedLocalizationEntry(languageCode: suggestedLangCode, isSeen: false))
                            } else {
                                return nil
                            }
                        }
                        return entry
                    })
                    
                    updateLimitsConfiguration(transaction: transaction, configuration: LimitsConfiguration(maxGroupMemberCount: chatSizeMax, maxSupergroupMemberCount: megagroupSizeMax, maxMessageForwardBatchSize: forwardedCountMax, maxRecentStickerCount: stickersRecentLimit, maxMessageEditingInterval: editTimeLimit, canRemoveIncomingMessagesInPrivateChats: (flags & (1 << 6)) != 0, maxMessageRevokeInterval: revokeTimeLimit, maxMessageRevokeIntervalInPrivateChats: revokePmTimeLimit))
                    
                    updateSearchBotsConfiguration(transaction: transaction, configuration: SearchBotsConfiguration(imageBotUsername: imgSearchUsername, gifBotUsername: gifSearchUsername, venueBotUsername: venueSearchUsername))
                
                    updateLinksConfiguration(transaction: transaction, configuration: LinksConfiguration(autologinToken: autologinToken))
                
                    if let defaultReaction = reactionsDefault, let reaction = MessageReaction.Reaction(apiReaction: defaultReaction) {
                        updateReactionSettings(transaction: transaction, { settings in
                            var settings = settings
                            settings.quickReaction = reaction
                            return settings
                        })
                    }
                
                    let messageAutoremoveSeconds: Int32?
                    switch defaultHistoryTtl {
                    case let .defaultHistoryTTL(defaultHistoryTTLData):
                        let period = defaultHistoryTTLData.period
                        if period != 0 {
                            messageAutoremoveSeconds = period
                        } else {
                            messageAutoremoveSeconds = nil
                        }
                    default:
                        messageAutoremoveSeconds = nil
                    }
                    updateGlobalMessageAutoremoveTimeoutSettings(transaction: transaction, { settings in
                        var settings = settings
                        settings.messageAutoremoveTimeout = messageAutoremoveSeconds
                        return settings
                    })
                
                    return accountManager.transaction { transaction -> Signal<Void, NoError> in
                        let (primary, secondary) = getLocalization(transaction)
                        var invalidateLocalization = false
                        if primary.version != langPackVersion {
                            invalidateLocalization = true
                        }
                        if let secondary = secondary, let baseLangPackVersion = baseLangPackVersion {
                            if secondary.version != baseLangPackVersion {
                                invalidateLocalization = true
                            }
                        }
                        if invalidateLocalization {
                            return postbox.transaction { transaction -> Void in
                                addSynchronizeLocalizationUpdatesOperation(transaction: transaction)
                            }
                        } else {
                            return .complete()
                        }
                    }
                    |> switchToLatest
                }
            }
            |> switchToLatest
        }).start(completed: {
            subscriber.putCompletion()
        })
    }
    
    return (poll |> then(.complete() |> suspendAwareDelay(1.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}
