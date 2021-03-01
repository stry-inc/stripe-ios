//
//  PaymentSheet+Helpers.swift
//  StripeiOS
//
//  Created by Yuki Tokuhiro on 12/10/20.
//  Copyright © 2020 Stripe, Inc. All rights reserved.
//

import Foundation
import UIKit

@available(iOSApplicationExtension, unavailable)
@available(macCatalystApplicationExtension, unavailable)
extension PaymentSheet {
    /// Confirms a PaymentIntent with the given PaymentOption and returns a PaymentResult
    static func confirm(configuration: PaymentSheet.Configuration,
                        authenticationContext: STPAuthenticationContext,
                        paymentIntent: STPPaymentIntent,
                        paymentOption: PaymentOption,
                        completion: @escaping (PaymentResult) -> ()) {
        // Translates a STPPaymentHandler result to a PaymentResult
        let paymentHandlerCompletion: STPPaymentHandlerActionPaymentIntentCompletionBlock = {
            (status, updatedPaymentIntent, error) in
            switch status {
            case .canceled:
                completion(.canceled(paymentIntent: updatedPaymentIntent))
            case .failed:
                let error: Error = error ?? PaymentSheetError.unknown(debugDescription: "STPPaymentHandler failed without an error")
                completion(.failed(error: error, paymentIntent: updatedPaymentIntent))
            case .succeeded:
                guard let paymentIntent = updatedPaymentIntent else { // Unfortunately optional due to Obj-C-ness
                    let error: Error = PaymentSheetError.unknown(debugDescription: "STPPaymentHandler completed with a nil PaymentIntent")
                    assertionFailure()
                    completion(.failed(error: error, paymentIntent: nil))
                    return
                }
                completion(.completed(paymentIntent: updatedPaymentIntent ?? paymentIntent))
            }
        }

        switch paymentOption {
        // MARK: Apple Pay
        case .applePay:
            guard let applePayConfiguration = configuration.applePay,
                  let applePayContext = STPApplePayContext.create(paymentIntent: paymentIntent,
                                                                  merchantName: configuration.merchantDisplayName,
                                                                  configuration: applePayConfiguration,
                                                                  completion: paymentHandlerCompletion)
            else {
                let message = "Attempted Apple Pay but it's not supported by the device, not configured, or missing a presenter"
                assertionFailure(message)
                let error = PaymentSheetError.unknown(debugDescription: message)
                completion(.failed(error: error, paymentIntent: paymentIntent))
                return
            }
            applePayContext.presentApplePay()

        // MARK: New Payment Method
        case let .new(paymentMethodParams, shouldSave):
            let paymentIntentParams = STPPaymentIntentParams(clientSecret: paymentIntent.clientSecret)
            if shouldSave  {
                paymentIntentParams.setupFutureUsage = STPPaymentIntentSetupFutureUsage.offSession
            }
            if let returnURL = configuration.returnURL {
                paymentIntentParams.returnURL = returnURL
            }

            if STPAPIClient.shared.publishableKey?.hasPrefix("uk_") ?? false {
                STPAPIClient.shared.createPaymentMethod(with: paymentMethodParams) { paymentMethod, error in
                    if let error = error {
                        completion(.failed(error: error, paymentIntent: paymentIntent))
                        return
                    }
                    paymentIntentParams.paymentMethodId = paymentMethod?.stripeId

                    let cardOptions = STPConfirmCardOptions()
                    cardOptions.additionalAPIParameters["moto"] = true
                    let paymentMethodOptions = STPConfirmPaymentMethodOptions()
                    paymentMethodOptions.cardOptions = cardOptions
                    paymentIntentParams.paymentMethodOptions = paymentMethodOptions
                    
                    STPPaymentHandler.shared().confirmPayment(paymentIntentParams,
                                                              with: authenticationContext,
                                                              completion: paymentHandlerCompletion)
                }
            } else {
                paymentIntentParams.paymentMethodParams = paymentMethodParams
                STPPaymentHandler.shared().confirmPayment(paymentIntentParams,
                                                          with: authenticationContext,
                                                          completion: paymentHandlerCompletion)
            }

        // MARK: Saved Payment Method
        case let .saved(paymentMethod):
            let paymentIntentParams = STPPaymentIntentParams(clientSecret: paymentIntent.clientSecret)
            paymentIntentParams.paymentMethodId = paymentMethod.stripeId
            STPPaymentHandler.shared().confirmPayment(paymentIntentParams,
                                                      with: authenticationContext,
                                                      completion: paymentHandlerCompletion)
        }
    }

    /// Fetches the PaymentIntent and Customer's saved PaymentMethods
    static func load(apiClient: STPAPIClient,
                     clientSecret: String,
                     ephemeralKey: String? = nil,
                     customerID: String? = nil,
                     completion: @escaping ((Result<(STPPaymentIntent, [STPPaymentMethod]), Error>) -> ())) {
        let paymentIntentPromise = Promise<STPPaymentIntent>()
        let paymentMethodsPromise = Promise<[STPPaymentMethod]>()
        paymentIntentPromise.observe { result in
            switch result {
            case .success(let paymentIntent):
                paymentMethodsPromise.observe { result in
                    switch result {
                    case .success(let paymentMethods):
                        let savedPaymentMethods = paymentMethods.filter {
                            // Filter out payment methods that the PaymentIntent or PaymentSheet doesn't support
                            let isSupportedByPaymentIntent = paymentIntent.paymentMethodTypes.contains($0.type.rawValue as NSNumber)
                            let isSupportedByPaymentSheet = PaymentSheet.supportedPaymentMethods.contains($0.type)
                            return isSupportedByPaymentIntent && isSupportedByPaymentSheet
                        }

                        completion(.success((paymentIntent, savedPaymentMethods)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }

        // Get the PaymentIntent
        apiClient.retrievePaymentIntent(withClientSecret: clientSecret) { paymentIntent, error in
            guard let paymentIntent = paymentIntent, error == nil else {
                let error = error ?? PaymentSheetError.unknown(debugDescription: "Failed to retrieve PaymentIntent")
                paymentIntentPromise.reject(with: error)
                return
            }

            guard paymentIntent.status == .requiresPaymentMethod else {
                let message = paymentIntent.status == .succeeded ?
                    "PaymentSheet received a PaymentIntent that is already completed!" :
                    "PaymentSheet received a PaymentIntent in an unexpected state: \(paymentIntent.status)"
                assertionFailure(message)
                completion(.failure(PaymentSheetError.unknown(debugDescription: message)))
                return
            }
            paymentIntentPromise.resolve(with: paymentIntent)
        }

        // List the Customer's saved PaymentMethods
        if let customerID = customerID, let ephemeralKey = ephemeralKey {
            apiClient.listPaymentMethods(forCustomer: customerID, using: ephemeralKey) { paymentMethods, error in
                guard let paymentMethods = paymentMethods, error == nil else {
                    let error = error ?? PaymentSheetError.unknown(debugDescription: "Failed to retrieve PaymentMethods for the customer")
                    paymentMethodsPromise.reject(with: error)
                    return
                }
                paymentMethodsPromise.resolve(with: paymentMethods)
            }
        } else {
            paymentMethodsPromise.resolve(with: [])
        }
    }
}

extension PaymentSheet {
    /// Returns a list of payment method types supported by PaymentSheet ordered from most recommended to least
    static func paymentMethodTypes(for paymentIntent: STPPaymentIntent, customerID: String?) -> [STPPaymentMethodType] {
        // TODO: Use the customer's last used PaymentMethod type
        return paymentIntent.paymentMethodTypes
            .compactMap { number in
                STPPaymentMethodType(rawValue: STPPaymentMethodType.RawValue(number.intValue))
            }.filter {
                supportedPaymentMethods.contains($0)
            }
    }
}
