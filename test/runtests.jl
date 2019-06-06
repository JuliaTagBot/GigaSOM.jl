using GigaSOM
using Test
using Random

#fix the seed
Random.seed!(1)

include("Fcs_load_and_transform.jl")

# #test cleannames
# for i in eachindex(lineage_markers)
#         test_clean = @test !in("-",i)
#         return test_clean
# end

#BATCH & PARALLEL

# only use lineage_markers for clustering
(lineage_markers,)= getMarkers(panel)

cc = map(Symbol, lineage_markers)

df_som = daf.fcstable[:,cc]
df_som_large = vcat(df_som,df_som)
df_som_large = vcat(df_som_large, df_som)
# topology is now always rectangular

som2 = initSOM_parallel(df_som, 10, 10)
# som2 = initSOM_parallel(df_som_large, 10, 10)

# using batch som with epochs
# @time som2 = trainSOM_parallel(som2, df_som, size(df_som)[1], epochs = 1)
@time som2 = trainSOM_parallel(som2, df_som_large, size(df_som_large)[1], epochs = 1)

@time mywinners = mapToSOM(som2, df_som)

codes = som2.codes
df_codes = DataFrame(codes)
names!(df_codes, Symbol.(som2.colNames))
CSV.write(gendatapath*"/batch_df_codes.csv", df_codes)
CSV.write(gendatapath*"/batch_mywinners.csv", mywinners)

refDatapath = "C:/Users/vasco.verissimo/work/git/hub/GigaSOM.jl/test/refData"

#Create the refData files when needed
# CSV.write(refDatapath*"/ref_batch_df_codes.csv", first(df_codes, 10))
# CSV.write(refDatapath*"/ref_batch_mywinners.csv"/ref_batch_mywinners.csv", first(mywinners, 10))

ref_batch_df_codes = CSV.File(refDatapath*"/ref_batch_df_codes.csv") |> DataFrame
ref_batch_mywinners = CSV.File(refDatapath*"/ref_batch_mywinners.csv") |> DataFrame
batch_df_codes_test = CSV.File(gendatapath*"/batch_df_codes.csv") |> DataFrame
batch_df_codes_test = first(batch_df_codes_test, 10)
batch_mywinners_test = CSV.File(gendatapath*"/batch_mywinners.csv") |> DataFrame
batch_mywinners_test = first(batch_mywinners_test, 10)

@test ref_batch_df_codes == batch_df_codes_test
@test ref_batch_mywinners == batch_mywinners_test
