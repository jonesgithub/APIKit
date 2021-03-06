import Foundation

#if APIKIT_DYNAMIC_FRAMEWORK
import LlamaKit
#endif

public let APIKitErrorDomain = "APIKitErrorDomain"

public protocol Request {
    typealias Response: Any
    
    var URLRequest: NSURLRequest? { get }
    
    func responseFromObject(object: AnyObject) -> Response?
}

public enum Method: String {
    case GET = "GET"
    case POST = "POST"
    case PUT = "PUT"
    case HEAD = "HEAD"
    case DELETE = "DELETE"
    case PATCH = "PATCH"
    case TRACE = "TRACE"
    case OPTIONS = "OPTIONS"
    case CONNECT = "CONNECT"
}

private var dataTaskResponseBufferKey = 0
private var dataTaskCompletionHandlerKey = 0

private extension NSURLSessionDataTask {
    private var responseBuffer: NSMutableData {
        if let responseBuffer = objc_getAssociatedObject(self, &dataTaskResponseBufferKey) as? NSMutableData {
            return responseBuffer
        } else {
            let responseBuffer = NSMutableData()
            objc_setAssociatedObject(self, &dataTaskResponseBufferKey, responseBuffer, UInt(OBJC_ASSOCIATION_RETAIN_NONATOMIC))
            return responseBuffer
        }
    }
    
    private var completionHandler: ((NSData, NSURLResponse?, NSError?) -> Void)? {
        get {
            return (objc_getAssociatedObject(self, &dataTaskCompletionHandlerKey) as? Box<(NSData, NSURLResponse?, NSError?) -> Void>)?.unbox
        }
        
        set {
            if let value = newValue  {
                objc_setAssociatedObject(self, &dataTaskCompletionHandlerKey, Box(value), UInt(OBJC_ASSOCIATION_RETAIN_NONATOMIC))
            } else {
                objc_setAssociatedObject(self, &dataTaskCompletionHandlerKey, nil, UInt(OBJC_ASSOCIATION_RETAIN_NONATOMIC))
            }
        }
    }
}

// use private, global scope variable until we can use stored class var in Swift 1.2
private var instancePairDictionary = [String: (API, NSURLSession)]()
private let instancePairSemaphore = dispatch_semaphore_create(1)

public class API: NSObject, NSURLSessionDelegate, NSURLSessionDataDelegate {
    // configurations
    public class func baseURL() -> NSURL {
        fatalError("API.baseURL() must be overrided in subclasses.")
    }
    
    public class func requestBodyBuilder() -> RequestBodyBuilder {
        return .JSON(writingOptions: nil)
    }

    public class func responseBodyParser() -> ResponseBodyParser {
        return .JSON(readingOptions: nil)
    }
    
    public class func URLSessionConfiguration() -> NSURLSessionConfiguration {
        return NSURLSessionConfiguration.defaultSessionConfiguration()
    }
    
    public class func URLSessionDelegateQueue() -> NSOperationQueue? {
        // nil indicates NSURLSession creates its own serial operation queue.
        // see doc of NSURLSession.init(configuration:delegate:delegateQueue:) for more details.
        return nil
    }
    
    // prevent instantiation
    override private init() {
        super.init()
    }
    
    // create session and instance of API for each subclasses
    private final class var instancePair: (API, NSURLSession) {
        let className = NSStringFromClass(self)
        
        dispatch_semaphore_wait(instancePairSemaphore, DISPATCH_TIME_FOREVER)
        let pair: (API, NSURLSession) = instancePairDictionary[className] ?? {
            let instance = (self as NSObject.Type)() as API
            let configuration = self.URLSessionConfiguration()
            let queue = self.URLSessionDelegateQueue()
            let session = NSURLSession(configuration: configuration, delegate: instance, delegateQueue: queue)
            let pair = (instance, session)
            instancePairDictionary[className] = pair
            return pair
        }()
        dispatch_semaphore_signal(instancePairSemaphore)
        
        return pair
    }
    
    public final class var instance: API {
        return instancePair.0
    }
    
    public final class var URLSession: NSURLSession {
        return instancePair.1
    }

    // build NSURLRequest
    public class func URLRequest(method: Method, _ path: String, _ parameters: [String: AnyObject] = [:]) -> NSURLRequest? {
        if let components = NSURLComponents(URL: baseURL(), resolvingAgainstBaseURL: true) {
            let request = NSMutableURLRequest()
            
            switch method {
            case .GET, .HEAD, .DELETE:
                components.query = URLEncodedSerialization.stringFromObject(parameters, encoding: NSUTF8StringEncoding)
                
            default:
                switch requestBodyBuilder().buildBodyFromObject(parameters) {
                case .Success(let box):
                    request.HTTPBody = box.unbox
                    
                case .Failure(let box):
                    return nil
                }
            }
            
            components.path = (components.path ?? "").stringByAppendingPathComponent(path)
            request.URL = components.URL
            request.HTTPMethod = method.rawValue
            request.setValue(requestBodyBuilder().contentTypeHeader, forHTTPHeaderField: "Content-Type")
            request.setValue(responseBodyParser().acceptHeader, forHTTPHeaderField: "Accept")
            
            return request
        } else {
            return nil
        }
    }

    // send request and build response object
    public class func sendRequest<T: Request>(request: T, handler: (Result<T.Response, NSError>) -> Void = {r in}) -> NSURLSessionDataTask? {
        let session = URLSession
        let mainQueue = dispatch_get_main_queue()
        
        if let URLRequest = request.URLRequest {
            let task = session.dataTaskWithRequest(URLRequest)
            
            task.completionHandler = { data, URLResponse, connectionError in
                if let error = connectionError {
                    dispatch_async(mainQueue, { handler(.Failure(Box(error))) })
                    return
                }
                
                let statusCode = (URLResponse as? NSHTTPURLResponse)?.statusCode ?? 0
                if !contains(200..<300, statusCode) {
                    let userInfo = [NSLocalizedDescriptionKey: "received status code that represents error"]
                    let error = NSError(domain: APIKitErrorDomain, code: statusCode, userInfo: userInfo)
                    dispatch_async(mainQueue, { handler(.Failure(Box(error))) })
                    return
                }
                
                let mappedResponse: Result<T.Response, NSError> = self.responseBodyParser().parseData(data).flatMap { rawResponse in
                    if let response = request.responseFromObject(rawResponse) {
                        return success(response)
                    } else {
                        let userInfo = [NSLocalizedDescriptionKey: "failed to create model object from raw object."]
                        let error = NSError(domain: APIKitErrorDomain, code: 0, userInfo: userInfo)
                        return failure(error)
                    }
                    
                }
                dispatch_async(mainQueue, { handler(mappedResponse) })
            }
            
            task.resume()

            return task
        } else {
            let userInfo = [NSLocalizedDescriptionKey: "failed to build request."]
            let error = NSError(domain: APIKitErrorDomain, code: 0, userInfo: userInfo)
            dispatch_async(mainQueue, { handler(failure(error)) })

            return nil
        }
    }
    
    // MARK: - NSURLSessionTaskDelegate
    // TODO: add attributes like NS_REQUIRES_SUPER when it is available in future version of Swift.
    public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError connectionError: NSError?) {
        if let dataTask = task as? NSURLSessionDataTask {
            dataTask.completionHandler?(dataTask.responseBuffer, dataTask.response, connectionError)
        }
    }

    // MARK: - NSURLSessionDataDelegate
    // TODO: add attributes like NS_REQUIRES_SUPER when it is available in future version of Swift.
    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
        dataTask.responseBuffer.appendData(data)
    }
}
