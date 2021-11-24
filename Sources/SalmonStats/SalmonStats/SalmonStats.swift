//
//  Manager.swift
//  
//
//  Created by tkgstrator on 2021/04/10.
//

import Foundation
import Alamofire
import Combine
import SplatNet2
import KeychainAccess

open class SalmonStats: SplatNet2 {
    public var apiToken: String? {
        get {
            try? keychain.getValue(key: .apiToken)
        }
        set {
            if let newValue = newValue {
                keychain.setValue(newValue, key: .apiToken)
            }
        }
    }
    
    public override init(version: String = "1.13.2") {
        super.init(version: version)
    }
    
    public func getMetadata(nsaid: String) -> AnyPublisher<[Metadata.Response], SP2Error> {
        let request = Metadata(nsaid: nsaid)
        return publish(request)
    }
    
    public func getPlayerMetadata(nsaid: String) -> AnyPublisher<[Player.Response], SP2Error> {
        let request = Player(nsaid: nsaid)
        return publish(request)
    }
    
    public func uploadResult(resultId: Int) -> AnyPublisher<[UploadResult.Response], SP2Error> {
        Future { [self] promise in
            getCoopResult(resultId: resultId)
                .subscribe(on: DispatchQueue(label: "SalmonStats"))
                .receive(on: DispatchQueue(label: "SalmonStats"))
                .flatMap({ publish(UploadResult(result: $0)) })
                .sink(receiveCompletion: { completion in
                    switch completion {
                        case .finished:
                            break
                        case .failure(let error):
                            promise(.failure(error))
                    }
                }, receiveValue: { response in
                    promise(.success(response))
                })
                .store(in: &task)
        }
        .eraseToAnyPublisher()
    }
    
    public func uploadResults(resultId: Int) -> AnyPublisher<[(UploadResult.Response, Result.Response)], SP2Error> {
        var results: [Result.Response] = []
        return Future { [self] promise in
            getCoopResults(resultId: resultId)
                .flatMap({ response -> Publishers.Sequence<[[Result.Response]], Never> in
                    results = response
                    return response.chunked(by: 10).publisher
                })
                .flatMap({ publish(UploadResult(results: $0)) })
//                .replaceError(with: UploadResult.ResponseType())
                .collect()
                .subscribe(on: DispatchQueue(label: "SalmonStats"))
                .receive(on: DispatchQueue(label: "SalmonStats"))
                .sink(receiveCompletion: { completion in
                    switch completion {
                        case .finished:
                            break
                        case .failure:
                            promise(.failure(SP2Error.Common(.badrequest, nil)))
                    }
                }, receiveValue: { response in
                    let salmonstats = response.flatMap({ $0 }).sorted(by: { $0.jobId < $1.jobId })
                    promise(.success(zip(salmonstats, results).map({ ($0.0, $0.1) })))
                })
                .store(in: &task)
        }
        .eraseToAnyPublisher()
    }
    
    public func getResults(from: Int, to: Int) -> AnyPublisher<[Result.Response], SP2Error> {
        Future { [self] promise in
            (from ... to).publisher
                .flatMap(maxPublishers: .max(1), { getResults(pageId: $0) })
                .subscribe(on: DispatchQueue(label: "SalmonStats"))
                .receive(on: DispatchQueue(label: "SalmonStats"))
                .collect()
                .sink(receiveCompletion: { completion in
                    print(completion)
                }, receiveValue: { response in
                    promise(.success(response.flatMap({ $0 })))
                })
                .store(in: &task)
        }
        .eraseToAnyPublisher()
    }
    
    public func getResults(pageId: Int, count: Int = 50) -> AnyPublisher<[Result.Response], SP2Error> {
        let request = ResultsStats(nsaid: account.nsaid, pageId: pageId, count: count)
        return Future { [self] promise in
            publish(request)
                .subscribe(on: DispatchQueue(label: "SalmonStats"))
                .receive(on: DispatchQueue(label: "SalmonStats"))
                .sink(receiveCompletion: { completion in
                    print(completion)
                }, receiveValue: { response in
                    promise(.success(response.results.map({ Result.Response(from: $0, playerId: account.nsaid) })))
                })
                .store(in: &task)
        }
        .eraseToAnyPublisher()
    }
    
    public func getResult(resultId: Int) -> AnyPublisher<Result.Response, SP2Error> {
        let request = ResultStats(resultId: resultId)
        return Future { [self] promise in
            publish(request)
                .subscribe(on: DispatchQueue(label: "SalmonStats"))
                .receive(on: DispatchQueue(label: "SalmonStats"))
                .sink(receiveCompletion: { completion in
                    switch completion {
                        case .finished:
                            break
                        case .failure(let error):
                            promise(.failure(error))
                    }
                }, receiveValue: { response in
                    promise(.success(Result.Response(from: response, playerId: account.nsaid)))
                })
                .store(in: &task)
        }
        .eraseToAnyPublisher()
    }
    
    override open func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Swift.Result<URLRequest, Error>) -> Void) {
        if let url = urlRequest.url?.absoluteString {
            if url.contains("salmon-stats") {
                guard let apiToken = apiToken else {
                    completion(.failure(SP2Error.OAuth(.code, nil)))
                    return
                }
                // Salmon Stats
                var urlRequest = urlRequest
                urlRequest.headers.add(.userAgent("Salmonia3/tkgling"))
                urlRequest.headers.add(.authorization(bearerToken: apiToken))
                completion(.success(urlRequest))
            } else {
                if sessionToken.isEmpty {
                    completion(.failure(SP2Error.Common(.unavailable, nil)))
                }
                // SplatNet2
                var urlRequest = urlRequest
                urlRequest.headers.add(.userAgent("Salmonia3/tkgling"))
                if !iksmSession.isEmpty {
                    urlRequest.headers.add(HTTPHeader(name: "cookie", value: "iksm_session=\(iksmSession)"))
                }
                completion(.success(urlRequest))
            }
        } else {
            completion(.failure(SP2Error.Common(.unavailable, nil)))
        }
    }
    
    override open func retry(_ request: Request, for session: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
        if let url = request.request?.url?.absoluteString {
            if url.contains("salmon-stats") {
                // SplatNet2
                guard let apiToken = apiToken else {
                    completion(.doNotRetry)
                    return
                }
            } else {
                // SplatNet2
                getCookie(sessionToken: sessionToken)
                    .sink(receiveCompletion: { result in
                        switch result {
                        case .finished:
                            break
                        case .failure(let error):
                            completion(.doNotRetry)
                        }
                    }, receiveValue: { response in
                        self.account = response
                        completion(.retry)
                    })
                    .store(in: &task)
            }
        } else {
            completion(.doNotRetry)
        }
    }
}

public enum KeyType: String, CaseIterable {
    case apiToken
}

extension Keychain {
    func setValue(_ value: String, key: KeyType) {
        try? set(value, key: key.rawValue)
    }
    
    func getValue(key: KeyType) throws -> String {
        guard let value = try? get(key.rawValue) else { throw SP2Error.OAuth(.response, nil) }
        return value
    }
}
