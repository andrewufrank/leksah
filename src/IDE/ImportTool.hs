-----------------------------------------------------------------------------
--
-- Module      :  IDE.ImportTool
-- Copyright   :  2007-2009 Jürgen Nicklisch-Franken
-- License     :  GPL
--
-- Maintainer  :  Jutaro <jutaro@leksah.org>
-- Stability   :  provisional
-- Portability :
--
-- | Help for constructing import statements
--
-----------------------------------------------------------------------------

module IDE.ImportTool (
    addAllImports
,   addOneImport
,   addImport
,   parseNotInScope
) where

import IDE.Core.State
import Data.Maybe (isNothing,isJust)
import IDE.Metainfo.Provider (getIdentifierDescr)
import Text.PrettyPrint (render)
import Distribution.Text (disp)
import IDE.Pane.SourceBuffer
        (fileSave, inActiveBufContext, selectSourceBuf)
import Graphics.UI.Gtk
import Text.ParserCombinators.Parsec.Language (haskellStyle)
import Graphics.UI.Editor.MakeEditor (buildEditor,mkField,FieldDescription(..))
import Graphics.UI.Editor.Parameters
       ((<<<-), paraMinSize, emptyParams, Parameter(..), paraMultiSel,
        paraName)
import Graphics.UI.Editor.Basics (eventPaneName,GUIEventSelector(..))
import Data.Maybe (fromJust)
import Text.ParserCombinators.Parsec hiding (parse)
import qualified Text.ParserCombinators.Parsec as Parsec (parse)
import Graphics.UI.Editor.Simple (okCancelFields, staticListEditor)
import Control.Event (registerEvent)
import Control.Monad.Trans (liftIO)
import Control.Monad (when)
import Distribution.Text(display)
import qualified Distribution.ModuleName as D(ModuleName(..))
import Data.List (sort, nub, nubBy)
import IDE.Utils.ServerConnection
import Text.PrinterParser (prettyPrint)
import IDE.TextEditor (delete, setModified, insert, getIterAtLine)
import qualified Text.ParserCombinators.Parsec.Token as P
       (operator, dot, identifier, symbol, lexeme, whiteSpace,
        makeTokenParser)


-- | Add all imports which gave error messages ...
addAllImports :: IDEAction
addAllImports = do
    prefs' <- readIDE prefs
    let buildInBackground = backgroundBuild prefs'
    when buildInBackground (
        modifyIDE_ (\ide -> ide{prefs = prefs'{backgroundBuild = False}}))
    errors <- readIDE errorRefs
    addAll
        [ y | (x,y) <-
            nubBy (\ (p1,_) (p2,_) -> p1 == p2)
                $ [(x,y) |  (x,y) <- [((parseNotInScope . refDescription) e, e) | e <- errors]],
                                isJust x] []
    when buildInBackground $
        modifyIDE_ (\ide -> ide{prefs = prefs'{backgroundBuild = True}})

    where
        addAll :: [LogRef] -> [Descr] -> IDEM ()
        addAll [] _                          =  return ()
        addAll (errorSpec:rest) descrList    =  addImport errorSpec descrList (addAll rest)

-- | Add import for current error ...
addOneImport :: IDEAction
addOneImport = do
    errors'     <- readIDE errorRefs
    currentErr' <- readIDE currentError
    case currentErr' of
        Nothing -> do
            ideMessage Normal $ "No error selected"
            return ()
        Just ref -> do
            addImport ref [] (\ _ -> return ())

-- | Add one missing import
-- Returns a boolean, if the process should be stopped in case of multiple addition
-- Returns a list of already added descrs, so that it will not be added two times and can
-- be used for default selection
addImport :: LogRef -> [Descr] -> ([Descr] -> IDEAction) -> IDEAction
addImport error descrList continuation =
    case parseNotInScope (refDescription error) of
        Nothing -> continuation descrList
        Just nis -> do
            currentInfo' <- readIDE packageInfo
            case currentInfo' of
                Nothing -> continuation descrList
                Just (GenScopeC(PackScope _ symbolTable1),GenScopeC(PackScope _ symbolTable2)) ->
                    case nub (getIdentifierDescr (id' nis) symbolTable1 symbolTable2) of
                        []          ->  do
                                            ideMessage Normal $ "Identifier " ++ (id' nis) ++
                                                " not found in imported packages"
                                            continuation descrList
                        descr : []  ->  addImport' nis (logRefFullFilePath error) descr descrList continuation
                        list        ->  do
                            window' <- getMainWindow
                            mbDescr <-  liftIO $ selectModuleDialog window' list (id' nis)
                                            (if null descrList
                                                then Nothing
                                                else Just (head descrList))
                            case mbDescr of
                                Nothing     ->  return ()
                                Just descr  ->  if elem descr descrList
                                                    then continuation descrList
                                                    else addImport' nis (logRefFullFilePath error)
                                                            descr descrList continuation

addImport' :: NotInScopeParseResult -> FilePath -> Descr -> [Descr] -> ([Descr] -> IDEAction) -> IDEAction
addImport' nis filePath descr descrList continuation =  do
    candy' <- readIDE candy
    mbBuf  <- selectSourceBuf filePath
    let mbMod  = case dsMbModu descr of
                    Nothing -> Nothing
                    Just pm -> Just (modu pm)
    case (mbBuf,mbMod) of
        (Just buf,Just mod) -> do
            inActiveBufContext () $ \ nb gtkbuf idebuf n ->
                doServerCommand (ParseHeaderCommand filePath)  $ \ res ->
                    case res of
                         ServerHeader (Left imports) ->
                            case filter (qualifyAsImportStatement mod) imports of
                                []     ->   let newLine  =  prettyPrint (newImpDecl mod) ++ "\n"
                                                lastLine = foldr max 0 (map (locationELine . importLoc) imports)
                                            in do
                                                i1 <- getIterAtLine gtkbuf lastLine
                                                insert gtkbuf i1 newLine
                                                fileSave False
                                                setModified gtkbuf True
                                                continuation (descr : descrList)
                                l@(impDecl:_) ->
                                                let newDecl     =  addToDecl impDecl
                                                    newLine     =  prettyPrint newDecl ++ "\n"
                                                    myLoc       =  importLoc impDecl
                                                    lineStart   =  locationSLine myLoc
                                                    lineEnd     =  locationELine myLoc
                                                in do
                                                    i1 <- getIterAtLine gtkbuf (lineStart - 1)
                                                    i2 <- getIterAtLine gtkbuf (lineEnd)
                                                    delete gtkbuf i1 i2
                                                    insert gtkbuf i1 newLine
                                                    fileSave False
                                                    setModified gtkbuf True
                                                    continuation (descr : descrList)
                         ServerHeader (Right lastLine) ->
                                            let newLine  =  prettyPrint (newImpDecl mod) ++ "\n"
                                            in do
                                                i1 <- getIterAtLine gtkbuf lastLine
                                                insert gtkbuf i1 newLine
                                                fileSave False
                                                setModified gtkbuf True
                                                continuation (descr : descrList)
                         ServerFailed string	-> do
                            ideMessage Normal ("Can't parse module header " ++ filePath ++
                                    " failed with: " ++ string)
                            return ()
                         _ ->    do
                            ideMessage Normal ("ImportTool>>addImport: Impossible server answer")
                            return ()
        _  -> return ()
    where
        qualifyAsImportStatement :: D.ModuleName -> ImportDecl -> Bool
        qualifyAsImportStatement moduleName impDecl =
            let importName = importModule impDecl
                getHiding (ImportSpecList isHiding _) = isHiding
            in importName == display moduleName
                && ((isNothing (mbQual' nis) &&  not (importQualified impDecl)) ||
                    (isJust (mbQual' nis) && importQualified impDecl
                        && fromJust (mbQual' nis) == qualString impDecl))
                && (isNothing (importSpecs impDecl) || not (getHiding (fromJust (importSpecs impDecl))))
        newImpDecl :: D.ModuleName -> ImportDecl
        newImpDecl mod = ImportDecl {
                        importLoc       = noLocation,
                        importModule    = display mod,
                        importQualified = isJust (mbQual' nis),
                        importSrc       = False,
                        importPkg       = Nothing,
                        importAs        = if isJust (mbQual' nis)
                                            then Just (fromJust (mbQual' nis))
                                            else Nothing,
                        importSpecs = (Just (ImportSpecList False [newImportSpec]))}
        newImportSpec :: ImportSpec
        newImportSpec =  if isSub' nis
                            then IThingAll  (getRealId descr (id' nis))
                            else if isOp' nis
                                    then IVar (id' nis)
                                    else IVar (id' nis) -- TODO ???
        addToDecl :: ImportDecl -> ImportDecl
        addToDecl impDecl = case importSpecs impDecl of
                                Just (ImportSpecList True listIE)  -> throwIDE "ImportTool>>addToDecl: ImpList is hiding"
                                Just (ImportSpecList False listIE) ->
                                    impDecl{importSpecs = Just (ImportSpecList False (newImportSpec : listIE))}
                                Nothing             ->
                                    impDecl{importSpecs = Just (ImportSpecList False [newImportSpec])}
        noLocation  = Location 0 0 0 0

getRealId descr id = case descr of
    Reexported rdescr -> getRealId (dsrDescr rdescr) id
    Real edescr -> getReal (dscTypeHint' edescr)
    where
        getReal (FieldDescr d) = dscName d
        getReal (ConstructorDescr d) = dscName d
        getReal (MethodDescr d) = dscName d
        getReal _ = id

qualString ::  ImportDecl -> String
qualString impDecl = case importAs impDecl of
                        Nothing -> ""
                        Just modName -> modName

-- | The import data

data NotInScopeParseResult = NotInScopeParseResult {
        mbQual' ::   Maybe String
    ,   id'     ::   String
    ,   isSub'  ::   Bool
    ,   isOp'   ::   Bool}
    deriving Eq

-- |* The error line parser

lexer      = P.makeTokenParser haskellStyle
whiteSpace = P.whiteSpace lexer
lexeme     = P.lexeme lexer
symbol     = P.symbol lexer
identifier = P.identifier lexer
dot        = P.dot lexer
operator   = P.operator lexer

parseNotInScope :: String -> (Maybe NotInScopeParseResult)
parseNotInScope str =
    case Parsec.parse scopeParser "" str of
        Left e   -> Nothing
        Right r  -> Just r

scopeParser :: CharParser () NotInScopeParseResult
scopeParser = do
    whiteSpace
    symbol "Not in scope:"
    isSub   <- optionMaybe (try (choice [symbol "type constructor or class"
                    , symbol "data constructor"]))
    symbol "`"
    mbQual <- optionMaybe (try (do
        q  <- lexeme conid
        dot
        return q))
    id     <- optionMaybe (try identifier)
    case id of
        Just id -> return (NotInScopeParseResult mbQual
                        (take (length id - 1) id)  (isJust isSub) False)
        Nothing -> do
            op <-   operator
            symbol "'"
            return (NotInScopeParseResult mbQual op (isJust isSub) True)
    <?> "scopeParser"

conid  = do
    c <-  upper
    cs <- many (alphaNum <|> oneOf "_'")
    return (c:cs)
        <?> "conid"


-- |* Where to insert the first import statement?
{--
figureOutImportLine :: String -> Module SrcSpanInfo -> Int
figureOutImportLine modSource (Module _ (Just (ModuleHead _ _ _ (Just exportSpecList))) _ _ _) =
    ((srcSpanEndLine . srcInfoSpan . ann) exportSpecList) + 1
figureOutImportLine modSource (Module _ (Just (ModuleHead mhl _ _ Nothing)) _ _ _)             =
    ((srcSpanEndLine . srcInfoSpan) mhl) + 1
figureOutImportLine modSource _                                                                =
    1
--}
-- |* The little dialog to choose between possible modules

moduleFields :: [String] -> String -> FieldDescription String
moduleFields list ident =
        mkField
            (paraName <<<- ParaName ("From which module is " ++ ident)
                $ paraMultiSel <<<- ParaMultiSel False
                    $ paraMinSize <<<- ParaMinSize (300,400)
                        $ emptyParams)
            (\ a -> a)
            (\ a b -> a)
            (staticListEditor ((nub . sort) list) id)

selectModuleDialog :: Window -> [Descr] -> String -> Maybe Descr -> IO (Maybe Descr)
selectModuleDialog parentWindow list id mbDescr = do
    let listWithMods        =  filter (isJust . dsMbModu) list
    let selectionList       =  map (render . disp . modu . fromJust . dsMbModu) listWithMods
    let mbSelectedString    =  case mbDescr of
                                    Nothing -> Nothing
                                    Just descr -> case dsMbModu descr of
                                                    Nothing -> Nothing
                                                    Just pm -> Just ((render . disp . modu) pm)
    let realSelectionString =  case mbSelectedString of
                                    Nothing -> head selectionList
                                    Just str -> if elem str selectionList
                                                    then str
                                                    else head selectionList
    dia               <- dialogNew
    windowSetTransientFor dia parentWindow
    upper             <- dialogGetUpper dia
    lower             <- dialogGetActionArea dia
    (widget,inj,ext,_) <- buildEditor (moduleFields selectionList id) realSelectionString
    (widget2,_,_,notifier)     <-   buildEditor okCancelFields ()
    registerEvent notifier Clicked (Left (\e -> do
            case eventPaneName e of
                "Ok"    ->  dialogResponse dia ResponseOk
                _       ->  dialogResponse dia ResponseCancel
            return e))
    boxPackStart upper widget PackGrow 7
    boxPackStart lower widget2 PackNatural 7
    widgetShowAll dia
    resp <- dialogRun dia
    value                      <- ext ([])
    widgetDestroy dia
    --find
    case (resp,value) of
        (ResponseOk,Just v)    -> return (Just (head
                                    (filter (\e -> case dsMbModu e of
                                        Nothing -> False
                                        Just pm -> (render . disp . modu) pm == v) list)))
        _                      -> return Nothing

