import Foundation
import APIKit
import XCTest
import Assertions
import OHHTTPStubs

class APITests: XCTestCase {
    class MockAPI: API {
        override class func baseURL() -> NSURL {
            return NSURL(string: "https://api.github.com")!
        }
        
        override class func requestBodyBuilder() -> RequestBodyBuilder {
            return .JSON(writingOptions: nil)
        }
        
        override class func responseBodyParser() -> ResponseBodyParser {
            return .JSON(readingOptions: nil)
        }
        
        class Endpoint {
            class Get: Request {
                typealias Response = [String: AnyObject]
                
                var URLRequest: NSURLRequest? {
                    return MockAPI.URLRequest(.GET, "/")
                }
                
                func responseFromObject(object: AnyObject) -> Response? {
                    return object as? [String: AnyObject]
                }
            }
        }
    }
    
    class AnotherMockAPI: API {
    }
    
    override func tearDown() {
        OHHTTPStubs.removeAllStubs()
        super.tearDown()
    }
    
    // MARK: - instance tests
    func testDifferentSessionsAreCreatedForEachClasses() {
        assert(MockAPI.URLSession, !=, AnotherMockAPI.URLSession)
    }
    
    func testSameSessionsAreUsedInSameClasses() {
        assertEqual(MockAPI.URLSession, MockAPI.URLSession)
        assertEqual(AnotherMockAPI.URLSession, AnotherMockAPI.URLSession)
    }
    
    func testDelegateOfSessions() {
        assertNotNil(MockAPI.URLSession.delegate as? MockAPI)
        assertNotNil(AnotherMockAPI.URLSession.delegate as? AnotherMockAPI)
    }
    
    // MARK: - integration tests
    func testSuccess() {
        let dictionary = ["key": "value"]
        let data = NSJSONSerialization.dataWithJSONObject(dictionary, options: nil, error: nil)!
        
        OHHTTPStubs.stubRequestsPassingTest({ request in
            return true
        }, withStubResponse: { request in
            return OHHTTPStubsResponse(data: data, statusCode: 200, headers: nil)
        })
        
        let expectation = expectationWithDescription("wait for response")
        let request = MockAPI.Endpoint.Get()
        
        MockAPI.sendRequest(request) { response in
            switch response {
            case .Success(let box):
                assert(box.unbox, ==, dictionary)
                
            case .Failure:
                XCTFail()
            }
            
            expectation.fulfill()
        }
        
        waitForExpectationsWithTimeout(1.0, handler: nil)
    }
    
    func testFailureOfConnection() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        
        OHHTTPStubs.stubRequestsPassingTest({ request in
            return true
        }, withStubResponse: { request in
            return OHHTTPStubsResponse(error: error)
        })
        
        let expectation = expectationWithDescription("wait for response")
        let request = MockAPI.Endpoint.Get()
        
        MockAPI.sendRequest(request) { response in
            switch response {
            case .Success:
                XCTFail()
                
            case .Failure(let box):
                let error = box.unbox
                assertEqual(error.domain, error.domain)
                assertEqual(error.code, error.code)
            }
            
            expectation.fulfill()
        }
        
        waitForExpectationsWithTimeout(1.0, handler: nil)
    }
    
    func testFailureOfResponseStatusCode() {
        OHHTTPStubs.stubRequestsPassingTest({ request in
            return true
        }, withStubResponse: { request in
            return OHHTTPStubsResponse(data: NSData(), statusCode: 400, headers: nil)
        })
        
        let expectation = expectationWithDescription("wait for response")
        let request = MockAPI.Endpoint.Get()
        
        MockAPI.sendRequest(request) { response in
            switch response {
            case .Success:
                XCTFail()
                
            case .Failure(let box):
                let error = box.unbox
                assertEqual(error.domain, APIKitErrorDomain)
                assertEqual(error.code, 400)
            }
            
            expectation.fulfill()
        }
        
        waitForExpectationsWithTimeout(1.0, handler: nil)
    }
    
    func testFailureOfDecodingResponseBody() {
        let data = "{\"broken\": \"json}".dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
        
        OHHTTPStubs.stubRequestsPassingTest({ request in
            return true
        }, withStubResponse: { request in
            return OHHTTPStubsResponse(data: data, statusCode: 200, headers: nil)
        })
        
        let expectation = expectationWithDescription("wait for response")
        let request = MockAPI.Endpoint.Get()
        
        MockAPI.sendRequest(request) { response in
            switch response {
            case .Success:
                XCTFail()
                
            case .Failure(let box):
                let error = box.unbox
                assert(error.domain, ==, NSCocoaErrorDomain)
                assertEqual(error.code, 3840)
            }
            
            expectation.fulfill()
        }
        
        waitForExpectationsWithTimeout(1.0, handler: nil)
    }
}
