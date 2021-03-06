USE [Aktienmodell]
GO
/****** Object:  UserDefinedFunction [calc].[tvfBloombergReturnsTimeseriesNew]    Script Date: 06.01.2020 10:12:18 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		  Panko Aliaksandr (PAA)
-- Create date: 16.12.2019 Last Changed 06.01.20
-- Description:	gets the returns for a security, defined by @ts_type and usually a bloomberg ticker like 'DTE GY Equity' or 'SMI index'
--              (adjusted) timeseries is fetched via calc.tvfBloombergAdjustedTimeseries from simid 4372 and adjustment factors from aktienmodell.bb.AdjustmentFactors
--              
--              @ts_type        BB Ticker. Only tickers in simts=4372 are considered
--              @indicatorId    the mnemonic, usually  'px_last' which is also the default
--              @minDate        start date (this date will not be returned)
--              @maxDate        end date
--              @useLogReturns  if false - normal returns are used, if true - log-returns
--              @relativeTo     if null: absolute returns are calculated, if benchmark_name: returns relative to @relativeTo
--				@returnType     is a flag with 2 values: 'r' and 'rf'. Value 'r' stands for ordinary returns,
--								'rf' means Return Factor ( return 1% = 0.01 corresponds to 1 + 0.01 = 1.01 Return Factor)
--				@annualize      is a logical flag. Value 'false' means ordinary returns, 'true' corresponds to annualized returns
-- =============================================
ALTER FUNCTION [calc].[tvfBloombergReturnsTimeseriesNew]
(
   @ts_type        AS NVARCHAR (200) = null,
   @indicatorId    AS NVARCHAR (80) = 'px_last',
   @minDate        AS DATE = NULL,    
   @maxDate        AS DATE = NULL,
   @useLogReturns  AS BIT = 'false',
   @relativeTo	   AS NVARCHAR(50) = null,
   @returnType     AS NVARCHAR(2) = 'r',
   @annualize      AS BIT = 'false'
)
RETURNS 
@RetTable TABLE 
(	
	[Date]  DATE,
	[Return] FLOAT,
	[RowNumber] INT,
	[DaysSinceMinDate] INT
)
AS
BEGIN
	-- Case: Returns are relative to an index
	IF @relativeTo IS NOT NULL
	BEGIN
		WITH stockAdjPrice AS
		(
		SELECT Datie AS [date],
			   RowNumber,
			   varAdjusted,
			   DaysSinceMinDate
		FROM calc.tvfBloombergAdjustedTimeseries (@ts_type,
												  @indicatorId,
												  @minDate,
												  @maxDate,
												  0)
		),
		indexAdjValue AS
		(
		SELECT Datie AS [date],
			   RowNumber,
			   varAdjusted,
			   DaysSinceMinDate
		FROM calc.tvfBloombergAdjustedTimeseries (@relativeTo,
												  @indicatorId,
												  @minDate,
												  @maxDate,
												  0)
		),
		joinedAdjPrice AS
		(
		SELECT ts1.[date],
			   ts1.varAdjusted AS priceTs,
			   ts2.varAdjusted AS priceTsLag1,
			   ts1.DaysSinceMinDate
		FROM stockAdjPrice AS  ts1 INNER JOIN stockAdjPrice AS ts2 
		ON ts1.RowNumber = ts2.RowNumber + 1
		),
		joinedAdjValue AS
		(
		SELECT ts1.[date],
			   ts1.varAdjusted AS priceTs,
			   ts2.varAdjusted AS priceTsLag1,
			   ts1.DaysSinceMinDate
		FROM indexAdjValue AS  ts1 INNER JOIN indexAdjValue AS ts2 
		ON ts1.RowNumber = ts2.RowNumber + 1
		),
		stockReturnsTable AS
		(
		SELECT [date],
			   DaysSinceMinDate,
				CASE
				  WHEN @useLogReturns = 'false' THEN
					-- R = (New_Price - Old_Price)/ Old_Price = New/Old - 1
					([priceTs] / [priceTsLag1]) - 1
				  ELSE
					-- use log returns:  r = ln(New/Old)
					-- LOG() calculates natural logarithm 
					LOG ([priceTs] / [priceTsLag1])
				  END [Return]

		FROM joinedAdjPrice
		),
		indexReturnsTable AS
		(
		SELECT [date],
			   DaysSinceMinDate,
				CASE
				  WHEN @useLogReturns = 'false' THEN
				  -- R = (New_Price - Old_Price)/ Old_Price = New/Old - 1
					([priceTs] / [priceTsLag1]) - 1
				  ELSE
					-- use log returns:  r = ln(New/Old)
					-- LOG() calculates natural logarithm 
					LOG ([priceTs] / [priceTsLag1])
				  END [Return]

		FROM joinedAdjValue
		),
		joinedReturnsTable as
		(
		SELECT st.[date],
			   [StockReturn] = st.[Return],
			   [IndexReturn] = ind.[Return],
			   st.DaysSinceMinDate
		FROM stockReturnsTable AS  st INNER JOIN indexReturnsTable AS ind
		ON st.[date] = ind.[date]
		),
		[power] AS
		(
			-- [power] = 1/number of years in a holding period = 1/allDays/365 = 365/allDays
			SELECT 365.0 / MAX(DaysSinceMinDate) AS [power] FROM joinedReturnsTable
		),
		totalReturn AS
		(
			-- Total_Return = PROD(1 + r_i) - 1 = e^ln(PROD) - 1 = e^SUM(ln(1 + r_i)) - 1
			--EXP(SUM(LOG())) is the same as prod() = (1 + total_return)
			SELECT EXP(SUM(LOG(1 + ([StockReturn] - [IndexReturn])))) AS totalReturn FROM joinedReturnsTable
		)
		INSERT INTO @RetTable ([date], [return],[RowNumber],[DaysSinceMinDate])
		SELECT DISTINCT
			CASE 
				WHEN @annualize = 'false' THEN
					[date]
				WHEN @annualize = 'true' THEN
					NULL
			END [date],
			CASE 
				WHEN @annualize = 'false' AND @returnType = 'r' THEN
					[StockReturn] - [IndexReturn]
				WHEN @annualize = 'false' AND @returnType = 'rf' THEN
				    1 + ([StockReturn] - [IndexReturn])
				WHEN @annualize = 'true' AND @returnType = 'r' THEN
					-- annualized return = (R_total + 1)^(1/n) - 1, where n is number of years
				    POWER(totalReturn, [power]) - 1
				WHEN @annualize = 'true' AND @returnType = 'rf' THEN
				    POWER(totalReturn, [power])
			END [return],
			CASE 
				WHEN @annualize = 'false' THEN
					row_number () OVER (ORDER BY [date] ASC)
				WHEN @annualize = 'true' THEN
					NULL
			END [RowNumber],
			CASE 
				WHEN @annualize = 'false' THEN
					[DaysSinceMinDate]
				WHEN @annualize = 'true' THEN
					NULL
			END [DaysSinceMinDate]
		FROM joinedReturnsTable, [power], totalReturn

	END

	ELSE -- Case: no benchmark, stock returns are calculated

	BEGIN

	WITH stockAdjPrice AS
	(
	SELECT  Datie AS [date],
			RowNumber,
			varAdjusted,
			DaysSinceMinDate
	FROM calc.tvfBloombergAdjustedTimeseries (@ts_type,
											  @indicatorId,
											  @minDate,
											  @maxDate,
											  0)
	),
	joinedAdjPrice AS
	(
	SELECT  ts1.[date],
			ts1.varAdjusted AS priceTs,
			ts2.varAdjusted AS priceTsLag1,
			ts1.DaysSinceMinDate
	FROM stockAdjPrice AS  ts1 INNER JOIN stockAdjPrice AS ts2 
	ON ts1.RowNumber = ts2.RowNumber + 1
	),
	stockReturnsTable AS
	(
	SELECT  [date],
			DaysSinceMinDate,
			CASE
				WHEN @useLogReturns = 'false' THEN
				-- R = (New_Price - Old_Price)/ Old_Price = New/Old - 1
				([priceTs] / [priceTsLag1]) - 1
				ELSE
				-- use log returns:  r = ln(New/Old)
				-- LOG() calculates natural logarithm 
				LOG ([priceTs] / [priceTsLag1])
				END [return]

	FROM joinedAdjPrice
	),
	[power] AS
	(
		-- [power] = 1/number of years in a holding period = 1/allDays/365 = 365/allDays
		SELECT 365.0 / MAX(DaysSinceMinDate) AS [power] FROM stockReturnsTable
	),
	totalReturn AS
	(
		--EXP(SUM(LOG())) is the same as prod() = (1 + total_return)
		SELECT EXP(SUM(LOG(1 + [return]))) AS totalReturn FROM stockReturnsTable
	)
	INSERT INTO @RetTable ([date], [return],[RowNumber],[DaysSinceMinDate])
		SELECT
			CASE 
				WHEN @annualize = 'false' THEN
					[date]
				WHEN @annualize = 'true' THEN
					NULL
			END [date],
			CASE 
				WHEN @annualize = 'false' AND @returnType = 'r' THEN
					[return]
				WHEN @annualize = 'false' AND @returnType = 'rf' THEN
				    1 + [return]
				WHEN @annualize = 'true' AND @returnType = 'r' THEN
					-- annualized return = (R_total + 1)^(1/n) - 1, where n is number of years
				    POWER(totalReturn, [power]) - 1
				WHEN @annualize = 'true' AND @returnType = 'rf' THEN
				    POWER(totalReturn, [power])
			END [return],
			CASE 
				WHEN @annualize = 'false' THEN
					row_number () OVER (ORDER BY [date] ASC)
				WHEN @annualize = 'true' THEN
					NULL
			END [RowNumber],
			CASE 
				WHEN @annualize = 'false' THEN
					[DaysSinceMinDate]
				WHEN @annualize = 'true' THEN
					NULL
			END [DaysSinceMinDate]
	FROM stockReturnsTable, [power], totalReturn
		
	END
	
	RETURN 
END