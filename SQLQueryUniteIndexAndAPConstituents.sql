USE [Aktienmodell]
GO
/****** Object:  UserDefinedFunction [misc].[tvfDistinctAPandBMConstituents]    Script Date: 20.12.2019 09:20:23 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Panko Aliaksandr (PAA)
-- Create date: 16.12.2019
-- Description:	The function derives constituents of an Analyst Portfolio and the corresponding benchmark,
-- unites these 2 sets and returns only distinct values.
-- =============================================
ALTER FUNCTION [misc].[tvfDistinctAPandBMConstituents]
(	
   @PortfolioID     AS NVARCHAR (200) = NULL,
   @Date			AS DATE = NULL
)
RETURNS TABLE 
AS
RETURN 
	WITH apConstituents AS
	(
		SELECT s.TS_type FROM tara.dbo.simtslookup s inner join tara.dbo.simts t
		ON s.TS_ID = t.TS_ID
		WHERE MarketID = @PortfolioID
		AND CONVERT(DATE, Dates) = @Date  
		AND IndicatorID = 'Portfolioweight'
		AND SimID = 4388
	), 
	bmName AS
	(
		SELECT BenchmarkTicker FROM config.CustomPortfolios WHERE Ticker = @PortfolioID
	),
	bmConstituents AS
	(
		SELECT s.TS_type FROM tara.dbo.simtslookup s inner join tara.dbo.simts t
		ON s.TS_ID = t.TS_ID
		WHERE MarketID = (select * from bmName)
		AND CONVERT(DATE, Dates) = @Date  
		AND IndicatorID = 'Portfolioweight'
		AND SimID = 4388 -- OR SimID = 4387
	)
	SELECT * FROM bmConstituents 
	UNION
	SELECT * FROM apConstituents 

