--
-- TODO: How do I avoid threading the 'proxy' argument to the various
-- functions in here?  
--
-- | URL Utility Functions
--

module Lib.Url (
    getHtmlPage,
    getHeader,
    rawPageTitle,
    urlPageTitle,
    urlTitlePrompt
    ) where

import Data.List
import Data.Maybe
import Text.Regex
import Lib.MiniHTTP

-- | The string that I prepend to the quoted page title.
urlTitlePrompt :: String
urlTitlePrompt = "Title: "

-- | Limit the maximum title length to prevent jokers from spamming
-- the channel with specially crafted HTML pages.
maxTitleLength :: Int
maxTitleLength = 80


-- | Replace occurences in a string.
-- e.g. replace [("foo", "1"), ("bar", "000")] "foo bar baz" => "1 000 baz"
replace :: [(String, String)] -> String -> String
replace [] s = s
replace (pair:pairs) s = replace pairs (f pair)
    where 
      f :: (String, String) -> String
      f (from, to) = subRegex (mkRegex from) s to

-- | Fetches a page title suitable for display.  Ideally, other
-- plugins should make use of this function if the result is to be
-- displayed in an IRC channel because it ensures that a consistent
-- look is used (and also lets the URL plugin effectively ignore
-- contextual URLs that might be generated by another instance of
-- lambdabot; the URL plugin matches on 'urlTitlePrompt').
urlPageTitle :: String -> Proxy -> IO (Maybe String)
urlPageTitle url proxy = do
    title <- rawPageTitle url proxy
    return $ maybe Nothing (return . prettyTitle . unhtml . urlDecode) title 
    where
      limitLength s
          | length s > maxTitleLength = (take maxTitleLength s) ++ " ..."
          | otherwise                 = s

      prettyTitle s = urlTitlePrompt ++ "\"" ++ limitLength s ++ "\""
      unhtml = replace [("&raquo;", "»"),
                        ("&iexcl;", "¡"),
                        ("&cent;", "¢"),
                        ("&copy;", "©"),
                        ("&laquo;", "«"),
                        ("&deg;", "°"),
                        ("&sup2;", "²"),
                        ("&micro;", "µ")] -- partial list of html entity pairs
                        
                       

-- | Fetches a page title for the specified URL.  This function should
-- only be used by other plugins if and only if the result is not to
-- be displayed in an IRC channel.  Instead, use 'urlPageTitle'.
rawPageTitle :: String -> Proxy -> IO (Maybe String)
rawPageTitle url proxy
    | Just uri <- parseURI url  = do
        contents <- getHtmlPage uri proxy
        return $ extractTitle contents
    | otherwise = return Nothing

-- | Fetch the contents of a URL following HTTP redirects.  It returns
-- a list of strings comprising the server response which includes the
-- status line, response headers, and body.
getHtmlPage :: URI -> Proxy -> IO [String]
getHtmlPage uri proxy = do
    contents <- getURIContents uri proxy
    case responseStatus contents of
      301       -> getHtmlPage (redirectedUrl contents) proxy
      302       -> getHtmlPage (redirectedUrl contents) proxy
      200       -> return contents
      _         -> return []
    where
      -- | Parse the HTTP response code from a line in the following
      -- format: HTTP/1.1 200 Success.
      responseStatus hdrs = (read . (!!1) . words . (!!0)) hdrs :: Int

      -- | Return the value of the "Location" header in the server
      -- response 
      redirectedUrl hdrs 
          | Just loc <- getHeader "Location" hdrs = 
              case parseURI loc of
                Nothing   -> (fromJust . parseURI) $ fullUrl loc
                Just uri' -> uri'
          | otherwise = error("No Location header found in 3xx response.")

      -- | Construct a full absolute URL based on the current uri.  This is 
      -- used when a Location header violates the HTTP RFC and does not send  
      -- an absolute URI in the response, instead, a relative URI is sent, so 
      -- we must manually construct the absolute URI.
      fullUrl loc = let auth = fromJust $ uriAuthority uri
                    in (uriScheme uri) ++ "//" ++
                       (uriRegName auth) ++
                       loc

-- | Fetch the contents of a URL returning a list of strings
-- comprising the server response which includes the status line,
-- response headers, and body.
getURIContents :: URI -> Proxy -> IO [String]
getURIContents uri proxy = readNBytes 1024 proxy uri request ""
    where
      request  = case proxy of
                   Nothing -> ["GET " ++ abs_path ++ " HTTP/1.1",
                               "host: " ++ host,
                               "Connection: close", ""]
                   _       -> ["GET " ++ show uri ++ " HTTP/1.0", ""]

      abs_path = case uriPath uri ++ uriQuery uri ++ uriFragment uri of
                   url@('/':_) -> url
                   url         -> '/':url

      host = uriRegName . fromJust $ uriAuthority uri

-- | Given a server response (list of Strings), return the text in
-- between the title HTML element, only if it is text/html content.
-- TODO: need to decode character entities (or at least the most
-- common ones)
extractTitle :: [String] -> Maybe String
extractTitle contents
    | isTextHtml contents = getTitle $ unlines contents
    | otherwise           = Nothing
    where
      begreg = mkRegexWithOpts "<title> *"  True False
      endreg = mkRegexWithOpts " *</title>" True False

      getTitle text = do
        (_,_,start,_) <- matchRegexAll begreg text
        (title,_,_,_) <- matchRegexAll endreg start
        return $ (unwords . words) title

-- | Is the server response of type "text/html"?
isTextHtml :: [String] -> Bool
isTextHtml []       = False
isTextHtml contents = val == "text/html"
    where
      val        = takeWhile (/=';') ctype
      Just ctype = getHeader "Content-Type" contents

-- | Retrieve the specified header from the server response being
-- careful to strip the trailing carriage return.  I swiped this code
-- from Search.hs, but had to modify it because it was not properly
-- stripping off the trailing CR (must not have manifested itself as a 
-- bug in that code; however, parseURI will fail against CR-terminated
-- strings.
getHeader :: String -> [String] -> Maybe String
getHeader _   []     = Nothing
getHeader hdr (_:hs) = lookup hdr $ concatMap mkassoc hs
    where
      removeCR   = takeWhile (/='\r')
      mkassoc s  = case findIndex (==':') s of
                    Just n  -> [(take n s, removeCR $ drop (n+2) s)]
                    Nothing -> []

